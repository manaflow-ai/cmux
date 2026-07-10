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

#ifndef CEF_INCLUDE_CEF_SCHEME_H_
#define CEF_INCLUDE_CEF_SCHEME_H_
#pragma once

#include "include/cef_base.h"
#include "include/cef_browser.h"
#include "include/cef_frame.h"
#include "include/cef_request.h"
#include "include/cef_resource_handler.h"
#include "include/cef_response.h"

class CefSchemeHandlerFactory;

///
/// Register a scheme handler factory with the global request context. An empty
/// |domain_name| value for a standard scheme will cause the factory to match
/// all domain names. The |domain_name| value will be ignored for non-standard
/// schemes. If |scheme_name| is a built-in scheme and no handler is returned by
/// |factory| then the built-in scheme handler factory will be called. If
/// |scheme_name| is a custom scheme then you must also implement the
/// CefApp::OnRegisterCustomSchemes() method in all processes. This function may
/// be called multiple times to change or remove the factory that matches the
/// specified |scheme_name| and optional |domain_name|. Returns false if an
/// error occurs. This function may be called on any thread in the browser
/// process. Using this function is equivalent to calling
/// CefRequestContext::GetGlobalContext()->RegisterSchemeHandlerFactory().
///
/*--cef(optional_param=domain_name,optional_param=factory)--*/
bool CefRegisterSchemeHandlerFactory(
    const CefString& scheme_name,
    const CefString& domain_name,
    CefRefPtr<CefSchemeHandlerFactory> factory);

///
/// Clear all scheme handler factories registered with the global request
/// context. Returns false on error. This function may be called on any thread
/// in the browser process. Using this function is equivalent to calling
/// CefRequestContext::GetGlobalContext()->ClearSchemeHandlerFactories().
///
/*--cef()--*/
bool CefClearSchemeHandlerFactories();

///
/// Class that manages custom scheme registrations.
///
/*--cef(source=library)--*/
class CefSchemeRegistrar : public CefBaseScoped {
 public:
  ///
  /// Register a custom scheme. This method should not be called for the
  /// built-in HTTP, HTTPS, FILE, FTP, ABOUT and DATA schemes.
  ///
  /// See cef_scheme_options_t for possible values for |options|.
  ///
  /// This function may be called on any thread. It should only be called once
  /// per unique |scheme_name| value. If |scheme_name| is already registered or
  /// if an error occurs this method will return false.
  ///
  /*--cef()--*/
  virtual bool AddCustomScheme(const CefString& scheme_name, int options) = 0;
};

///
/// Class that creates CefResourceHandler instances for handling scheme
/// requests. The methods of this class will always be called on the IO thread.
///
/*--cef(source=client,no_debugct_check)--*/
class CefSchemeHandlerFactory : public virtual CefBaseRefCounted {
 public:
  ///
  /// Return a new resource handler instance to handle the request or an empty
  /// reference to allow default handling of the request. |browser| and |frame|
  /// will be the browser window and frame respectively that originated the
  /// request or NULL if the request did not originate from a browser window
  /// (for example, if the request came from CefURLRequest). The |request|
  /// object passed to this method cannot be modified.
  ///
  /*--cef(optional_param=browser,optional_param=frame)--*/
  virtual CefRefPtr<CefResourceHandler> Create(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      const CefString& scheme_name,
      CefRefPtr<CefRequest> request) = 0;
};

#endif  // CEF_INCLUDE_CEF_SCHEME_H_
