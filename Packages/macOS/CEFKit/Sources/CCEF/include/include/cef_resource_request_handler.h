// Copyright (c) 2011 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_RESOURCE_REQUEST_HANDLER_H_
#define CEF_INCLUDE_CEF_RESOURCE_REQUEST_HANDLER_H_
#pragma once

#include "include/cef_base.h"
#include "include/cef_browser.h"
#include "include/cef_callback.h"
#include "include/cef_frame.h"
#include "include/cef_request.h"
#include "include/cef_resource_handler.h"
#include "include/cef_response.h"
#include "include/cef_response_filter.h"

class CefCookieAccessFilter;

///
/// Implement this interface to handle events related to browser requests. The
/// methods of this class will be called on the IO thread unless otherwise
/// indicated.
///
/*--cef(source=client,no_debugct_check)--*/
class CefResourceRequestHandler : public virtual CefBaseRefCounted {
 public:
  typedef cef_return_value_t ReturnValue;
  typedef cef_urlrequest_status_t URLRequestStatus;

  ///
  /// Called on the IO thread before a resource request is loaded. The |browser|
  /// and |frame| values represent the source of the request, and may be NULL
  /// for requests originating from service workers or CefURLRequest. To
  /// optionally filter cookies for the request return a CefCookieAccessFilter
  /// object. The |request| object cannot not be modified in this callback.
  ///
  /*--cef(optional_param=browser,optional_param=frame)--*/
  virtual CefRefPtr<CefCookieAccessFilter> GetCookieAccessFilter(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request) {
    return nullptr;
  }

  ///
  /// Called on the IO thread before a resource request is loaded. The |browser|
  /// and |frame| values represent the source of the request, and may be NULL
  /// for requests originating from service workers or CefURLRequest. To
  /// redirect or change the resource load optionally modify |request|.
  /// Modification of the request URL will be treated as a redirect. Return
  /// RV_CONTINUE to continue the request immediately. Return RV_CONTINUE_ASYNC
  /// and call CefCallback methods at a later time to continue or cancel the
  /// request asynchronously. Return RV_CANCEL to cancel the request
  /// immediately.
  ///
  /*--cef(optional_param=browser,optional_param=frame,
          default_retval=RV_CONTINUE)--*/
  virtual ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                           CefRefPtr<CefFrame> frame,
                                           CefRefPtr<CefRequest> request,
                                           CefRefPtr<CefCallback> callback) {
    return RV_CONTINUE;
  }

  ///
  /// Called on the IO thread before a resource is loaded. The |browser| and
  /// |frame| values represent the source of the request, and may be NULL for
  /// requests originating from service workers or CefURLRequest. To allow the
  /// resource to load using the default network loader return NULL. To specify
  /// a handler for the resource return a CefResourceHandler object. The
  /// |request| object cannot not be modified in this callback.
  ///
  /*--cef(optional_param=browser,optional_param=frame)--*/
  virtual CefRefPtr<CefResourceHandler> GetResourceHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request) {
    return nullptr;
  }

  ///
  /// Called on the IO thread when a resource load is redirected. The |browser|
  /// and |frame| values represent the source of the request, and may be NULL
  /// for requests originating from service workers or CefURLRequest. The
  /// |request| parameter will contain the old URL and other request-related
  /// information. The |response| parameter will contain the response that
  /// resulted in the redirect. The |new_url| parameter will contain the new URL
  /// and can be changed if desired. The |request| and |response| objects cannot
  /// be modified in this callback.
  ///
  /*--cef(optional_param=browser,optional_param=frame)--*/
  virtual void OnResourceRedirect(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  CefRefPtr<CefRequest> request,
                                  CefRefPtr<CefResponse> response,
                                  CefString& new_url) {}

  ///
  /// Called on the IO thread when a resource response is received. The
  /// |browser| and |frame| values represent the source of the request, and may
  /// be NULL for requests originating from service workers or CefURLRequest. To
  /// allow the resource load to proceed without modification return false. To
  /// redirect or retry the resource load optionally modify |request| and return
  /// true. Modification of the request URL will be treated as a redirect.
  /// Requests handled using the default network loader cannot be redirected in
  /// this callback. The |response| object cannot be modified in this callback.
  ///
  /// WARNING: Redirecting using this method is deprecated. Use
  /// OnBeforeResourceLoad or GetResourceHandler to perform redirects.
  ///
  /*--cef(optional_param=browser,optional_param=frame)--*/
  virtual bool OnResourceResponse(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  CefRefPtr<CefRequest> request,
                                  CefRefPtr<CefResponse> response) {
    return false;
  }

  ///
  /// Called on the IO thread to optionally filter resource response content.
  /// The |browser| and |frame| values represent the source of the request, and
  /// may be NULL for requests originating from service workers or
  /// CefURLRequest. |request| and |response| represent the request and response
  /// respectively and cannot be modified in this callback.
  ///
  /*--cef(optional_param=browser,optional_param=frame)--*/
  virtual CefRefPtr<CefResponseFilter> GetResourceResponseFilter(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      CefRefPtr<CefResponse> response) {
    return nullptr;
  }

  ///
  /// Called on the IO thread when a resource load has completed. The |browser|
  /// and |frame| values represent the source of the request, and may be NULL
  /// for requests originating from service workers or CefURLRequest. |request|
  /// and |response| represent the request and response respectively and cannot
  /// be modified in this callback. |status| indicates the load completion
  /// status. |received_content_length| is the number of response bytes actually
  /// read. This method will be called for all requests, including requests that
  /// are aborted due to CEF shutdown or destruction of the associated browser.
  /// In cases where the associated browser is destroyed this callback may
  /// arrive after the CefLifeSpanHandler::OnBeforeClose callback for that
  /// browser. The CefFrame::IsValid method can be used to test for this
  /// situation, and care should be taken not to call |browser| or |frame|
  /// methods that modify state (like LoadURL, SendProcessMessage, etc.) if the
  /// frame is invalid.
  ///
  /*--cef(optional_param=browser,optional_param=frame)--*/
  virtual void OnResourceLoadComplete(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      CefRefPtr<CefRequest> request,
                                      CefRefPtr<CefResponse> response,
                                      URLRequestStatus status,
                                      int64_t received_content_length) {}

  ///
  /// Called on the IO thread to handle requests for URLs with an unknown
  /// protocol component. The |browser| and |frame| values represent the source
  /// of the request, and may be NULL for requests originating from service
  /// workers or CefURLRequest. |request| cannot be modified in this callback.
  /// Set |allow_os_execution| to true to attempt execution via the registered
  /// OS protocol handler, if any. SECURITY WARNING: YOU SHOULD USE THIS METHOD
  /// TO ENFORCE RESTRICTIONS BASED ON SCHEME, HOST OR OTHER URL ANALYSIS BEFORE
  /// ALLOWING OS EXECUTION.
  ///
  /*--cef(optional_param=browser,optional_param=frame)--*/
  virtual void OnProtocolExecution(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   bool& allow_os_execution) {}
};

///
/// Implement this interface to filter cookies that may be sent or received from
/// resource requests. The methods of this class will be called on the IO thread
/// unless otherwise indicated.
///
/*--cef(source=client,no_debugct_check)--*/
class CefCookieAccessFilter : public virtual CefBaseRefCounted {
 public:
  ///
  /// Called on the IO thread before a resource request is sent. The |browser|
  /// and |frame| values represent the source of the request, and may be NULL
  /// for requests originating from service workers or CefURLRequest. |request|
  /// cannot be modified in this callback. Return true if the specified cookie
  /// can be sent with the request or false otherwise.
  ///
  /*--cef(optional_param=browser,optional_param=frame)--*/
  virtual bool CanSendCookie(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefRequest> request,
                             const CefCookie& cookie) {
    return true;
  }

  ///
  /// Called on the IO thread after a resource response is received. The
  /// |browser| and |frame| values represent the source of the request, and may
  /// be NULL for requests originating from service workers or CefURLRequest.
  /// |request| cannot be modified in this callback. Return true if the
  /// specified cookie returned with the response can be saved or false
  /// otherwise.
  ///
  /*--cef(optional_param=browser,optional_param=frame)--*/
  virtual bool CanSaveCookie(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefRequest> request,
                             CefRefPtr<CefResponse> response,
                             const CefCookie& cookie) {
    return true;
  }
};

#endif  // CEF_INCLUDE_CEF_RESOURCE_REQUEST_HANDLER_H_
