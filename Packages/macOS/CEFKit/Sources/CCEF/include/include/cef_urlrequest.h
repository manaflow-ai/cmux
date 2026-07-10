// Copyright (c) 2012 Marshall A. Greenblatt. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the name Chromium Embedded
// Framework nor the names of its contributors may be used to endorse
// or promote products derived from this software without specific prior
// written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// ---------------------------------------------------------------------------
//
// The contents of this file must follow a specific format in order to
// support the CEF translator tool. See the translator.README.txt file in the
// tools directory for more information.
//

#ifndef CEF_INCLUDE_CEF_URLREQUEST_H_
#define CEF_INCLUDE_CEF_URLREQUEST_H_
#pragma once

#include "include/cef_auth_callback.h"
#include "include/cef_base.h"
#include "include/cef_request.h"
#include "include/cef_request_context.h"
#include "include/cef_response.h"

class CefURLRequestClient;

///
/// Class used to make a URL request. URL requests are not associated with a
/// browser instance so no CefClient callbacks will be executed. URL requests
/// can be created on any valid CEF thread in either the browser or render
/// process. Once created the methods of the URL request object must be accessed
/// on the same thread that created it.
///
/*--cef(source=library)--*/
class CefURLRequest : public virtual CefBaseRefCounted {
 public:
  typedef cef_urlrequest_status_t Status;
  typedef cef_errorcode_t ErrorCode;

  ///
  /// Create a new URL request that is not associated with a specific browser or
  /// frame. Use CefFrame::CreateURLRequest instead if you want the request to
  /// have this association, in which case it may be handled differently (see
  /// documentation on that method). A request created with this method may only
  /// originate from the browser process, and will behave as follows:
  ///   - It may be intercepted by the client via CefResourceRequestHandler or
  ///     CefSchemeHandlerFactory.
  ///   - POST data may only contain only a single element of type PDE_TYPE_FILE
  ///     or PDE_TYPE_BYTES.
  ///   - If |request_context| is empty the global request context will be used.
  ///
  /// The |request| object will be marked as read-only after calling this
  /// method.
  ///
  /*--cef(optional_param=request_context)--*/
  static CefRefPtr<CefURLRequest> Create(
      CefRefPtr<CefRequest> request,
      CefRefPtr<CefURLRequestClient> client,
      CefRefPtr<CefRequestContext> request_context);

  ///
  /// Returns the request object used to create this URL request. The returned
  /// object is read-only and should not be modified.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefRequest> GetRequest() = 0;

  ///
  /// Returns the client.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefURLRequestClient> GetClient() = 0;

  ///
  /// Returns the request status.
  ///
  /*--cef(default_retval=UR_UNKNOWN)--*/
  virtual Status GetRequestStatus() = 0;

  ///
  /// Returns the request error if status is UR_CANCELED or UR_FAILED, or 0
  /// otherwise.
  ///
  /*--cef(default_retval=ERR_NONE)--*/
  virtual ErrorCode GetRequestError() = 0;

  ///
  /// Returns the response, or NULL if no response information is available.
  /// Response information will only be available after the upload has
  /// completed. The returned object is read-only and should not be modified.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefResponse> GetResponse() = 0;

  ///
  /// Returns true if the response body was served from the cache. This includes
  /// responses for which revalidation was required.
  ///
  /*--cef()--*/
  virtual bool ResponseWasCached() = 0;

  ///
  /// Cancel the request.
  ///
  /*--cef()--*/
  virtual void Cancel() = 0;
};

///
/// Interface that should be implemented by the CefURLRequest client. The
/// methods of this class will be called on the same thread that created the
/// request unless otherwise documented.
///
/*--cef(source=client)--*/
class CefURLRequestClient : public virtual CefBaseRefCounted {
 public:
  ///
  /// Notifies the client that the request has completed. Use the
  /// CefURLRequest::GetRequestStatus method to determine if the request was
  /// successful or not.
  ///
  /*--cef()--*/
  virtual void OnRequestComplete(CefRefPtr<CefURLRequest> request) = 0;

  ///
  /// Notifies the client of upload progress. |current| denotes the number of
  /// bytes sent so far and |total| is the total size of uploading data (or -1
  /// if chunked upload is enabled). This method will only be called if the
  /// UR_FLAG_REPORT_UPLOAD_PROGRESS flag is set on the request.
  ///
  /*--cef()--*/
  virtual void OnUploadProgress(CefRefPtr<CefURLRequest> request,
                                int64_t current,
                                int64_t total) = 0;

  ///
  /// Notifies the client of download progress. |current| denotes the number of
  /// bytes received up to the call and |total| is the expected total size of
  /// the response (or -1 if not determined).
  ///
  /*--cef()--*/
  virtual void OnDownloadProgress(CefRefPtr<CefURLRequest> request,
                                  int64_t current,
                                  int64_t total) = 0;

  ///
  /// Called when some part of the response is read. |data| contains the current
  /// bytes received since the last call. This method will not be called if the
  /// UR_FLAG_NO_DOWNLOAD_DATA flag is set on the request.
  ///
  /*--cef()--*/
  virtual void OnDownloadData(CefRefPtr<CefURLRequest> request,
                              const void* data,
                              size_t data_length) = 0;

  ///
  /// Called on the IO thread when the browser needs credentials from the user.
  /// |isProxy| indicates whether the host is a proxy server. |host| contains
  /// the hostname and |port| contains the port number. Return true to continue
  /// the request and call CefAuthCallback::Continue() when the authentication
  /// information is available. If the request has an associated browser/frame
  /// then returning false will result in a call to GetAuthCredentials on the
  /// CefRequestHandler associated with that browser, if any. Otherwise,
  /// returning false will cancel the request immediately. This method will only
  /// be called for requests initiated from the browser process.
  ///
  /*--cef(optional_param=realm)--*/
  virtual bool GetAuthCredentials(bool isProxy,
                                  const CefString& host,
                                  int port,
                                  const CefString& realm,
                                  const CefString& scheme,
                                  CefRefPtr<CefAuthCallback> callback) = 0;
};

#endif  // CEF_INCLUDE_CEF_URLREQUEST_H_
