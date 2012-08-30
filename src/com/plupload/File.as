/**
 * File.as
 *
 * Copyright 2009, Moxiecode Systems AB
 * Released under GPL License.
 *
 * License: http://www.plupload.com/license
 * Contributing: http://www.plupload.com/contributing
 */

package com.plupload {
	import com.formatlos.BitmapDataUnlimited;
	import com.formatlos.events.BitmapDataUnlimitedEvent;
	import flash.display.Bitmap;
	import flash.display.BitmapData;
	import flash.display.IBitmapDrawable;
	import flash.events.EventDispatcher;
	import flash.geom.Matrix;
	import flash.net.FileReference;
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.HTTPStatusEvent;
	import flash.events.ProgressEvent;
	import flash.events.SecurityErrorEvent;
	import flash.events.DataEvent;
	import flash.net.FileReferenceList;
	import flash.net.URLLoader;
	import flash.net.URLRequest;
	import flash.net.URLRequestHeader;
	import flash.net.URLRequestMethod;
	import flash.net.URLStream;
	import flash.net.URLVariables;
	import flash.utils.ByteArray;
	import flash.utils.setTimeout;
	import flash.external.ExternalInterface;
	import com.mxi.image.events.ExifParserEvent;
	
	import com.mxi.image.Image;
	import com.mxi.image.events.ImageEvent;
	import mx.utils.Base64Encoder;
	
	
	/**
	 * Container class for file references, this handles upload logic for individual files.
	 */
	public class File extends EventDispatcher {
		// Private fields
		private var _fileRef:FileReference, _urlStream:URLStream, _cancelled:Boolean;
		private var _uploadUrl:String, _uploadPath:String, _mimeType:String;
		private var _id:String, _fileName:String, _size:Number, _imageData:ByteArray;
		private var _multipart:Boolean, _fileDataName:String, _chunking:Boolean, _chunk:int, _chunks:int, _chunkSize:int, _postvars:Object;
		private var _headers:Object, _settings:Object;
		private var _removeAllListeners:Function;
		private var _removeAllURLStreamListeners:Function;
		private var _sessionID:String;

		/**
		 * Id property of file.
		 */
		public function get id():String {
			return this._id;
		}

		/**
		 * File name for the file.
		 */
		public function get fileName():String {
			return this._fileName;
		}

		/**
		 * File name for the file.
		 */
		public function set fileName(value:String):void {
			this._fileName = value;
		}

		/**
		 * File size property.
		 */
		public function get size():Number {
			return this._size;
		}

		/**
		 * Constructs a new file object.
		 *
		 * @param id Unique indentifier for the file.
		 * @param file_ref File reference for the selected file.
		 */
		public function File(id:String, file_ref:FileReference) {
			this._id = id;
			this._fileRef = file_ref;
			this._size = file_ref.size;
			this._fileName = file_ref.name;
			var encoder:Base64Encoder = new Base64Encoder();
			encoder.encode(this._fileName);
			this._sessionID = new Date().time.toString() + "_" + encoder.toString().replace(/\+|=|\//g, '');
		}
		
		/**
		 * Cancel current upload.
		 */
		public function cancelUpload(): void
		{
			if (!this._urlStream) {
				// In case of a large file and before _fileRef.load#COMPLETE.
				// Need to cancel() twice, not sure why.
				// If single cancel(), #2037 will occurred at _fileRef.load().
				this._fileRef.cancel();
				this._fileRef.cancel();
				this._removeAllListeners();
			} else if (this._urlStream.connected) {
				// just in case
				this._removeAllURLStreamListeners();

				this._urlStream.close();

				// In case of a large file and after the first uploadNextChunk().
				// #2174 will occur at _fileRef.load() and
				// #2029 will occur at _urlStream.readUTFBytes as well
				// after loading file is stopped before _fileRef.load#COMPLETE.
		
				// Uploaded file will be broken as well if the following line does not exist.
				this._urlStream = null;
			} 
		}

		/**
		 * Uploads a the file to the specified url. This method will upload it as a normal
		 * multipart file upload if the file size is smaller than the chunk size. But if the file is to
		 * large it will be chunked into multiple requests.
		 *
		 * @param url Url to upload the file to.
		 * @param settings Settings object.
		 */
		public function upload(url:String, settings:Object):void {
			this._settings = settings;

			this.advancedUpload(url, settings);
		}

		// Private methods

		public function advancedUpload(url:String, settings:Object):void {
			var file:File = this, width:int, height:int, quality:int, multipart:Boolean, chunking:Boolean, fileDataName:String;
			var chunk:int, chunks:int, chunkSize:int, postvars:Object;
			var onComplete:Function, onIOError:Function;
			var removeAllListeners:Function = function() : void {
					file._fileRef.removeEventListener(Event.COMPLETE, onComplete);
					file._fileRef.removeEventListener(IOErrorEvent.IO_ERROR, onIOError);
				};

			// Setup internal vars
			this._uploadUrl = url;
			this._cancelled = false;
			this._headers = settings.headers;
			this._mimeType = settings.mime;
			
			// make it available for whole class (cancelUpload requires it for example)
			this._removeAllListeners = removeAllListeners;

			multipart = false;
			fileDataName = new String(settings["file_data_name"]);
			chunkSize = settings["chunk_size"];
			chunking = chunkSize > 0;
			postvars = settings["multipart_params"];
			chunk = 0;

			// When file is loaded start uploading
			onComplete = function(e:Event):void {
				removeAllListeners();
				
				var startUpload:Function = function() : void
				{
					if (chunking) {
						chunks = Math.ceil(file._size / chunkSize);

						// Force at least 4 chunks to fake progress. We need to fake this since the URLLoader
						// doesn't have a upload progress event and we can't use FileReference.upload since it
						// doesn't support cookies, breaks on HTTPS and doesn't support custom data so client
						// side image resizing will not be possible.
						if (chunks < 4 && file._size > 1024 * 32) {
							chunkSize = Math.ceil(file._size / 4);
							chunks = 4;
						}
					} else {
						// If chunking is disabled then upload file in one huge chunk
						chunkSize = file._size;
						chunks = 1;
					}

					// Start uploading the scaled down image
					file._multipart = multipart;
					file._fileDataName = fileDataName;
					file._chunking = chunking;
					file._chunk = chunk;
					file._chunks = chunks;
					file._chunkSize = chunkSize;
					file._postvars = postvars;

					file.uploadNextChunk();
				}
								
				if (/\.(jpeg|jpg|png)$/i.test(file._fileName) && (settings["width"] || settings["height"] || settings["quality"])) {
					var image:Image = new Image(file._fileRef.data);
					image.addEventListener(ImageEvent.COMPLETE, function(e:ImageEvent) : void 
					{
						image.removeAllEventListeners();
						if (image.imageData) {
							file._imageData = image.imageData;
							file._imageData.position = 0;
							file._size = image.imageData.length;
						}
						startUpload();
					});
					image.addEventListener(ImageEvent.ERROR, function(e:ImageEvent) : void
					{
						image.removeAllEventListeners();
						file.dispatchEvent(e);
					});
					image.addEventListener(ExifParserEvent.EXIF_DATA, function(e:ExifParserEvent) : void
					{
						file.dispatchEvent(e);
					});
					image.addEventListener(ExifParserEvent.GPS_DATA, function(e:ExifParserEvent) : void
					{
						file.dispatchEvent(e);
					});
					image.scale(settings["width"], settings["height"], settings["quality"]);
				} else {
					startUpload();
				}					
			};
			this._fileRef.addEventListener(Event.COMPLETE, onComplete);

			// File load IO error
			onIOError = function(e:Event):void {
				removeAllListeners();
				dispatchEvent(e);
			};
			this._fileRef.addEventListener(IOErrorEvent.IO_ERROR, onIOError);

			// Start loading local file
			this._fileRef.load();
		}

		/**
		 * Uploads the next chunk or terminates the upload loop if all chunks are done.
		 */
		public function uploadNextChunk():Boolean {
			var file:File = this, fileData:ByteArray, chunkData:ByteArray, req:URLRequest, url:String;
			var onComplete:Function, onIOError:Function, onSecurityError:Function;
			var removeAllEventListeners:Function = function() : void {
					file._urlStream.removeEventListener(Event.COMPLETE, onComplete);
					file._urlStream.removeEventListener(IOErrorEvent.IO_ERROR, onIOError);
					file._urlStream.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityError);
				};
				
			this._removeAllURLStreamListeners = removeAllEventListeners;

			// All chunks uploaded?
			if (this._chunk >= this._chunks) {
				// Clean up memory
				if(this._fileRef.data) {
					this._fileRef.data.clear();
				}
				this._imageData = null;

				return false;
			}

			// Slice out a chunk
			chunkData = new ByteArray();

			// Use image data if it exists, will exist if the image was resized
			if (this._imageData != null)
				fileData = this._imageData;
			else
				fileData = this._fileRef.data;

			fileData.readBytes(chunkData, 0, fileData.position + this._chunkSize > fileData.length ? fileData.length - fileData.position : this._chunkSize);

			// Setup URL stream
			file._urlStream = null;
			file._urlStream = new URLStream();

			// Wait for response and dispatch it
			onComplete = function(e:Event):void {
				

				var response:String = file._urlStream.readUTFBytes(file._urlStream.bytesAvailable);
				
				// Fake UPLOAD_COMPLETE_DATA event
				var uploadChunkEvt:UploadChunkEvent = new UploadChunkEvent(
					UploadChunkEvent.UPLOAD_CHUNK_COMPLETE_DATA,
					false,
					false,
					response,
					file._chunk,
					file._chunks
				);

				file._chunk++;
				dispatchEvent(uploadChunkEvt);

				// Fake progress event since Flash doesn't have a progress event for streaming data up to the server
				var pe:ProgressEvent = new ProgressEvent(ProgressEvent.PROGRESS, false, false, fileData.position, file._size);
				dispatchEvent(pe);

				// Clean up memory
				file._urlStream.close();
				removeAllEventListeners();
				chunkData.clear();
			};
			file._urlStream.addEventListener(Event.COMPLETE, onComplete);

			// Try one more time
			onIOError = function(e:IOErrorEvent):void {
				setTimeout(function() : void {
                    file._urlStream.load(req);
                }, 30000);
			};
			file._urlStream.addEventListener(IOErrorEvent.IO_ERROR, onIOError);

			// Delegate security errors
			onSecurityError = function(e:SecurityErrorEvent):void {
				removeAllEventListeners();
				dispatchEvent(e);
			};
			file._urlStream.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityError);

			// Setup URL
			url = this._uploadUrl;

			// Setup request
			req = new URLRequest(url);
			req.method = URLRequestMethod.POST;

			// Add custom headers
			if (this._headers) {
				for (var headerName:String in this._headers) {
					req.requestHeaders.push(new URLRequestHeader(headerName, this._headers[headerName]));
				}
			}

			req.requestHeaders.push(new URLRequestHeader("Content-Type", "application/octet-stream"));
			var start:int, end:int;
			start = this._chunk * this._chunkSize;
			end = start + this._chunkSize - 1;
			if (end >= this._size) end = this._size - 1;
			req.requestHeaders.push(new URLRequestHeader("X-Content-Range", "bytes " + start.toString() + "-" + end.toString() + "/" + this._size.toString()));
			req.requestHeaders.push(new URLRequestHeader("Content-Disposition", "attachment; filename=\"" + this._sessionID + "." + this._fileName.split(".").pop() + "\""));
			req.requestHeaders.push(new URLRequestHeader("Session-ID", this._sessionID));
			req.data = chunkData;

			// Make request
			setTimeout(function() : void { // otherwise URLStream eventually hangs for Chrome+Flash (as of FP11.2 r202)
				file._urlStream.load(req);
			}, 1);
			return true;
		}
	}
}
