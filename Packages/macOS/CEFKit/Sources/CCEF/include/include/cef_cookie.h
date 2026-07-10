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

#ifndef CEF_INCLUDE_CEF_COOKIE_H_
#define CEF_INCLUDE_CEF_COOKIE_H_
#pragma once

#include <vector>

#include "include/cef_base.h"
#include "include/cef_callback.h"

class CefCookieVisitor;
class CefSetCookieCallback;
class CefDeleteCookiesCallback;

///
/// Class used for managing cookies. The methods of this class may be called on
/// any thread unless otherwise indicated.
///
/*--cef(source=library,no_debugct_check)--*/
class CefCookieManager : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns the global cookie manager. By default data will be stored at
  /// cef_settings_t.cache_path if specified or in memory otherwise. If
  /// |callback| is non-NULL it will be executed asnychronously on the UI thread
  /// after the manager's storage has been initialized. Using this method is
  /// equivalent to calling
  /// CefRequestContext::GetGlobalContext()->GetDefaultCookieManager().
  ///
  /*--cef(optional_param=callback)--*/
  static CefRefPtr<CefCookieManager> GetGlobalManager(
      CefRefPtr<CefCompletionCallback> callback);

  ///
  /// Visit all cookies on the UI thread. The returned cookies are ordered by
  /// longest path, then by earliest creation date. Returns false if cookies
  /// cannot be accessed.
  ///
  /*--cef()--*/
  virtual bool VisitAllCookies(CefRefPtr<CefCookieVisitor> visitor) = 0;

  ///
  /// Visit a subset of cookies on the UI thread. The results are filtered by
  /// the given url scheme, host, domain and path. If |includeHttpOnly| is true
  /// HTTP-only cookies will also be included in the results. The returned
  /// cookies are ordered by longest path, then by earliest creation date.
  /// Returns false if cookies cannot be accessed.
  ///
  /*--cef()--*/
  virtual bool VisitUrlCookies(const CefString& url,
                               bool includeHttpOnly,
                               CefRefPtr<CefCookieVisitor> visitor) = 0;

  ///
  /// Sets a cookie given a valid URL and explicit user-provided cookie
  /// attributes. This function expects each attribute to be well-formed. It
  /// will check for disallowed characters (e.g. the ';' character is disallowed
  /// within the cookie value attribute) and fail without setting the cookie if
  /// such characters are found. If |callback| is non-NULL it will be executed
  /// asnychronously on the UI thread after the cookie has been set. Returns
  /// false if an invalid URL is specified or if cookies cannot be accessed.
  ///
  /*--cef(optional_param=callback)--*/
  virtual bool SetCookie(const CefString& url,
                         const CefCookie& cookie,
                         CefRefPtr<CefSetCookieCallback> callback) = 0;

  ///
  /// Delete all cookies that match the specified parameters. If both |url| and
  /// |cookie_name| values are specified all host and domain cookies matching
  /// both will be deleted. If only |url| is specified all host cookies (but not
  /// domain cookies) irrespective of path will be deleted. If |url| is empty
  /// all cookies for all hosts and domains will be deleted. If |callback| is
  /// non-NULL it will be executed asnychronously on the UI thread after the
  /// cookies have been deleted. Returns false if a non-empty invalid URL is
  /// specified or if cookies cannot be accessed. Cookies can alternately be
  /// deleted using the Visit*Cookies() methods.
  ///
  /*--cef(optional_param=url,optional_param=cookie_name,
          optional_param=callback)--*/
  virtual bool DeleteCookies(const CefString& url,
                             const CefString& cookie_name,
                             CefRefPtr<CefDeleteCookiesCallback> callback) = 0;

  ///
  /// Flush the backing store (if any) to disk. If |callback| is non-NULL it
  /// will be executed asnychronously on the UI thread after the flush is
  /// complete. Returns false if cookies cannot be accessed.
  ///
  /*--cef(optional_param=callback)--*/
  virtual bool FlushStore(CefRefPtr<CefCompletionCallback> callback) = 0;
};

///
/// Interface to implement for visiting cookie values. The methods of this class
/// will always be called on the UI thread.
///
/*--cef(source=client)--*/
class CefCookieVisitor : public virtual CefBaseRefCounted {
 public:
  ///
  /// Method that will be called once for each cookie. |count| is the 0-based
  /// index for the current cookie. |total| is the total number of cookies.
  /// Set |deleteCookie| to true to delete the cookie currently being visited.
  /// Return false to stop visiting cookies. This method may never be called if
  /// no cookies are found.
  ///
  /*--cef()--*/
  virtual bool Visit(const CefCookie& cookie,
                     int count,
                     int total,
                     bool& deleteCookie) = 0;
};

///
/// Interface to implement to be notified of asynchronous completion via
/// CefCookieManager::SetCookie().
///
/*--cef(source=client)--*/
class CefSetCookieCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// Method that will be called upon completion. |success| will be true if the
  /// cookie was set successfully.
  ///
  /*--cef()--*/
  virtual void OnComplete(bool success) = 0;
};

///
/// Interface to implement to be notified of asynchronous completion via
/// CefCookieManager::DeleteCookies().
///
/*--cef(source=client)--*/
class CefDeleteCookiesCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// Method that will be called upon completion. |num_deleted| will be the
  /// number of cookies that were deleted.
  ///
  /*--cef()--*/
  virtual void OnComplete(int num_deleted) = 0;
};

#endif  // CEF_INCLUDE_CEF_COOKIE_H_
