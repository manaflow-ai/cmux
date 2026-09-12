// Copyright (c) 2014 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_NAVIGATION_ENTRY_H_
#define CEF_INCLUDE_CEF_NAVIGATION_ENTRY_H_
#pragma once

#include "include/cef_base.h"
#include "include/cef_ssl_status.h"

///
/// Class used to represent an entry in navigation history.
///
/*--cef(source=library)--*/
class CefNavigationEntry : public virtual CefBaseRefCounted {
 public:
  typedef cef_transition_type_t TransitionType;

  ///
  /// Returns true if this object is valid. Do not call any other methods if
  /// this function returns false.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns the actual URL of the page. For some pages this may be data: URL
  /// or similar. Use GetDisplayURL() to return a display-friendly version.
  ///
  /*--cef()--*/
  virtual CefString GetURL() = 0;

  ///
  /// Returns a display-friendly version of the URL.
  ///
  /*--cef()--*/
  virtual CefString GetDisplayURL() = 0;

  ///
  /// Returns the original URL that was entered by the user before any
  /// redirects.
  ///
  /*--cef()--*/
  virtual CefString GetOriginalURL() = 0;

  ///
  /// Returns the title set by the page. This value may be empty.
  ///
  /*--cef()--*/
  virtual CefString GetTitle() = 0;

  ///
  /// Returns the transition type which indicates what the user did to move to
  /// this page from the previous page.
  ///
  /*--cef(default_retval=TT_EXPLICIT)--*/
  virtual TransitionType GetTransitionType() = 0;

  ///
  /// Returns true if this navigation includes post data.
  ///
  /*--cef()--*/
  virtual bool HasPostData() = 0;

  ///
  /// Returns the time for the last known successful navigation completion. A
  /// navigation may be completed more than once if the page is reloaded. May be
  /// 0 if the navigation has not yet completed.
  ///
  /*--cef()--*/
  virtual CefBaseTime GetCompletionTime() = 0;

  ///
  /// Returns the HTTP status code for the last known successful navigation
  /// response. May be 0 if the response has not yet been received or if the
  /// navigation has not yet completed.
  ///
  /*--cef()--*/
  virtual int GetHttpStatusCode() = 0;

  ///
  /// Returns the SSL information for this navigation entry.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefSSLStatus> GetSSLStatus() = 0;
};

#endif  // CEF_INCLUDE_CEF_NAVIGATION_ENTRY_H_
