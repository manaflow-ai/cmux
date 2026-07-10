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

#ifndef CEF_INCLUDE_CEF_LOAD_HANDLER_H_
#define CEF_INCLUDE_CEF_LOAD_HANDLER_H_
#pragma once

#include "include/cef_base.h"
#include "include/cef_browser.h"
#include "include/cef_frame.h"

///
/// Implement this interface to handle events related to browser load status.
/// The methods of this class will be called on the browser process UI thread or
/// render process main thread (TID_RENDERER).
///
/*--cef(source=client)--*/
class CefLoadHandler : public virtual CefBaseRefCounted {
 public:
  typedef cef_errorcode_t ErrorCode;
  typedef cef_transition_type_t TransitionType;

  ///
  /// Called when the loading state has changed. This callback will be executed
  /// twice -- once when loading is initiated either programmatically or by user
  /// action, and once when loading is terminated due to completion,
  /// cancellation of failure. It will be called before any calls to OnLoadStart
  /// and after all calls to OnLoadError and/or OnLoadEnd.
  ///
  /*--cef()--*/
  virtual void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                    bool isLoading,
                                    bool canGoBack,
                                    bool canGoForward) {}

  ///
  /// Called after a navigation has been committed and before the browser begins
  /// loading contents in the frame. The |frame| value will never be empty --
  /// call the IsMain() method to check if this frame is the main frame.
  /// |transition_type| provides information about the source of the navigation
  /// and an accurate value is only available in the browser process. Multiple
  /// frames may be loading at the same time. Sub-frames may start or continue
  /// loading after the main frame load has ended. This method will not be
  /// called for same page navigations (fragments, history state, etc.) or for
  /// navigations that fail or are canceled before commit. For notification of
  /// overall browser load status use OnLoadingStateChange instead.
  ///
  /*--cef()--*/
  virtual void OnLoadStart(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           TransitionType transition_type) {}

  ///
  /// Called when the browser is done loading a frame. The |frame| value will
  /// never be empty -- call the IsMain() method to check if this frame is the
  /// main frame. Multiple frames may be loading at the same time. Sub-frames
  /// may start or continue loading after the main frame load has ended. This
  /// method will not be called for same page navigations (fragments, history
  /// state, etc.) or for navigations that fail or are canceled before commit.
  /// For notification of overall browser load status use OnLoadingStateChange
  /// instead.
  ///
  /*--cef()--*/
  virtual void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         int httpStatusCode) {}

  ///
  /// Called when a navigation fails or is canceled. This method may be called
  /// by itself if before commit or in combination with OnLoadStart/OnLoadEnd if
  /// after commit. |errorCode| is the error code number, |errorText| is the
  /// error text and |failedUrl| is the URL that failed to load.
  /// See net\base\net_error_list.h for complete descriptions of the error
  /// codes.
  ///
  /*--cef(optional_param=errorText)--*/
  virtual void OnLoadError(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           ErrorCode errorCode,
                           const CefString& errorText,
                           const CefString& failedUrl) {}
};

#endif  // CEF_INCLUDE_CEF_LOAD_HANDLER_H_
