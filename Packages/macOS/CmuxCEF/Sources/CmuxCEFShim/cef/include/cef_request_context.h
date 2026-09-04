// Copyright (c) 2013 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_REQUEST_CONTEXT_H_
#define CEF_INCLUDE_CEF_REQUEST_CONTEXT_H_
#pragma once

#include <vector>

#include "include/cef_callback.h"
#include "include/cef_cookie.h"
#include "include/cef_media_router.h"
#include "include/cef_preference.h"
#include "include/cef_registration.h"
#include "include/cef_values.h"

class CefRequestContextHandler;
class CefSchemeHandlerFactory;

///
/// Callback interface for CefRequestContext::ResolveHost.
///
/*--cef(source=client)--*/
class CefResolveCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// Called on the UI thread after the ResolveHost request has completed.
  /// |result| will be the result code. |resolved_ips| will be the list of
  /// resolved IP addresses or empty if the resolution failed.
  ///
  /*--cef(optional_param=resolved_ips)--*/
  virtual void OnResolveCompleted(
      cef_errorcode_t result,
      const std::vector<CefString>& resolved_ips) = 0;
};

#if CEF_API_ADDED(13401)
///
/// Implemented by the client to observe content and website setting changes and
/// registered via CefRequestContext::AddSettingObserver. The methods of this
/// class will be called on the browser process UI thread.
///
/*--cef(source=client,added=13401)--*/
class CefSettingObserver : public virtual CefBaseRefCounted {
 public:
  ///
  /// Called when a content or website setting has changed. The new value can be
  /// retrieved using CefRequestContext::GetContentSetting or
  /// CefRequestContext::GetWebsiteSetting.
  ///
  /*--cef(optional_param=requesting_url,optional_param=top_level_url)--*/
  virtual void OnSettingChanged(const CefString& requesting_url,
                                const CefString& top_level_url,
                                cef_content_setting_types_t content_type) = 0;
};
#endif

///
/// A request context provides request handling for a set of related browser
/// or URL request objects. A request context can be specified when creating a
/// new browser via the CefBrowserHost static factory methods or when creating a
/// new URL request via the CefURLRequest static factory methods. Browser
/// objects with different request contexts will never be hosted in the same
/// render process. Browser objects with the same request context may or may not
/// be hosted in the same render process depending on the process model. Browser
/// objects created indirectly via the JavaScript window.open function or
/// targeted links will share the same render process and the same request
/// context as the source browser. When running in single-process mode there is
/// only a single render process (the main process) and so all browsers created
/// in single-process mode will share the same request context. This will be the
/// first request context passed into a CefBrowserHost static factory method and
/// all other request context objects will be ignored.
///
/*--cef(source=library,no_debugct_check)--*/
class CefRequestContext : public CefPreferenceManager {
 public:
  ///
  /// Returns the global context object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefRequestContext> GetGlobalContext();

  ///
  /// Creates a new context object with the specified |settings| and optional
  /// |handler|.
  ///
  /*--cef(optional_param=handler)--*/
  static CefRefPtr<CefRequestContext> CreateContext(
      const CefRequestContextSettings& settings,
      CefRefPtr<CefRequestContextHandler> handler);

  ///
  /// Creates a new context object that shares storage with |other| and uses an
  /// optional |handler|.
  ///
  /*--cef(capi_name=cef_create_context_shared,optional_param=handler)--*/
  static CefRefPtr<CefRequestContext> CreateContext(
      CefRefPtr<CefRequestContext> other,
      CefRefPtr<CefRequestContextHandler> handler);

  ///
  /// Returns true if this object is pointing to the same context as |that|
  /// object.
  ///
  /*--cef()--*/
  virtual bool IsSame(CefRefPtr<CefRequestContext> other) = 0;

  ///
  /// Returns true if this object is sharing the same storage as |that| object.
  ///
  /*--cef()--*/
  virtual bool IsSharingWith(CefRefPtr<CefRequestContext> other) = 0;

  ///
  /// Returns true if this object is the global context. The global context is
  /// used by default when creating a browser or URL request with a NULL context
  /// argument.
  ///
  /*--cef()--*/
  virtual bool IsGlobal() = 0;

  ///
  /// Returns the handler for this context if any.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefRequestContextHandler> GetHandler() = 0;

  ///
  /// Returns the cache path for this object. If empty an "incognito mode"
  /// in-memory cache is being used.
  ///
  /*--cef()--*/
  virtual CefString GetCachePath() = 0;

  ///
  /// Returns the cookie manager for this object. If |callback| is non-NULL it
  /// will be executed asnychronously on the UI thread after the manager's
  /// storage has been initialized.
  ///
  /*--cef(optional_param=callback)--*/
  virtual CefRefPtr<CefCookieManager> GetCookieManager(
      CefRefPtr<CefCompletionCallback> callback) = 0;

  ///
  /// Register a scheme handler factory for the specified |scheme_name| and
  /// optional |domain_name|. An empty |domain_name| value for a standard scheme
  /// will cause the factory to match all domain names. The |domain_name| value
  /// will be ignored for non-standard schemes. If |scheme_name| is a built-in
  /// scheme and no handler is returned by |factory| then the built-in scheme
  /// handler factory will be called. If |scheme_name| is a custom scheme then
  /// you must also implement the CefApp::OnRegisterCustomSchemes() method in
  /// all processes. This function may be called multiple times to change or
  /// remove the factory that matches the specified |scheme_name| and optional
  /// |domain_name|. Returns false if an error occurs. This function may be
  /// called on any thread in the browser process.
  ///
  /*--cef(optional_param=domain_name,optional_param=factory)--*/
  virtual bool RegisterSchemeHandlerFactory(
      const CefString& scheme_name,
      const CefString& domain_name,
      CefRefPtr<CefSchemeHandlerFactory> factory) = 0;

  ///
  /// Clear all registered scheme handler factories. Returns false on error.
  /// This function may be called on any thread in the browser process.
  ///
  /*--cef()--*/
  virtual bool ClearSchemeHandlerFactories() = 0;

  ///
  /// Clears all certificate exceptions that were added as part of handling
  /// CefRequestHandler::OnCertificateError(). If you call this it is
  /// recommended that you also call CloseAllConnections() or you risk not
  /// being prompted again for server certificates if you reconnect quickly.
  /// If |callback| is non-NULL it will be executed on the UI thread after
  /// completion.
  ///
  /*--cef(optional_param=callback)--*/
  virtual void ClearCertificateExceptions(
      CefRefPtr<CefCompletionCallback> callback) = 0;

#if CEF_API_ADDED(14400)
  ///
  /// Clears the HTTP cache. If |callback| is non-NULL it will be executed on
  /// the UI thread after completion.
  ///
  /*--cef(added=14400,optional_param=callback)--*/
  virtual void ClearHttpCache(CefRefPtr<CefCompletionCallback> callback) = 0;
#endif

  ///
  /// Clears all HTTP authentication credentials that were added as part of
  /// handling GetAuthCredentials. If |callback| is non-NULL it will be executed
  /// on the UI thread after completion.
  ///
  /*--cef(optional_param=callback)--*/
  virtual void ClearHttpAuthCredentials(
      CefRefPtr<CefCompletionCallback> callback) = 0;

  ///
  /// Clears all active and idle connections that Chromium currently has.
  /// This is only recommended if you have released all other CEF objects but
  /// don't yet want to call CefShutdown(). If |callback| is non-NULL it will be
  /// executed on the UI thread after completion.
  ///
  /*--cef(optional_param=callback)--*/
  virtual void CloseAllConnections(
      CefRefPtr<CefCompletionCallback> callback) = 0;

  ///
  /// Attempts to resolve |origin| to a list of associated IP addresses.
  /// |callback| will be executed on the UI thread after completion.
  ///
  /*--cef()--*/
  virtual void ResolveHost(const CefString& origin,
                           CefRefPtr<CefResolveCallback> callback) = 0;

  ///
  /// Returns the MediaRouter object associated with this context.  If
  /// |callback| is non-NULL it will be executed asnychronously on the UI thread
  /// after the manager's context has been initialized.
  ///
  /*--cef(optional_param=callback)--*/
  virtual CefRefPtr<CefMediaRouter> GetMediaRouter(
      CefRefPtr<CefCompletionCallback> callback) = 0;

  ///
  /// Returns the current value for |content_type| that applies for the
  /// specified URLs. If both URLs are empty the default value will be returned.
  /// Returns nullptr if no value is configured. Must be called on the browser
  /// process UI thread.
  ///
  /*--cef(optional_param=requesting_url,optional_param=top_level_url)--*/
  virtual CefRefPtr<CefValue> GetWebsiteSetting(
      const CefString& requesting_url,
      const CefString& top_level_url,
      cef_content_setting_types_t content_type) = 0;

  ///
  /// Sets the current value for |content_type| for the specified URLs in the
  /// default scope. If both URLs are empty, and the context is not incognito,
  /// the default value will be set. Pass nullptr for |value| to remove the
  /// default value for this content type.
  ///
  /// WARNING: Incorrect usage of this method may cause instability or security
  /// issues in Chromium. Make sure that you first understand the potential
  /// impact of any changes to |content_type| by reviewing the related source
  /// code in Chromium. For example, if you plan to modify
  /// CEF_CONTENT_SETTING_TYPE_POPUPS, first review and understand the usage of
  /// ContentSettingsType::POPUPS in Chromium:
  /// https://source.chromium.org/search?q=ContentSettingsType::POPUPS
  ///
  /*--cef(optional_param=requesting_url,optional_param=top_level_url,
          optional_param=value)--*/
  virtual void SetWebsiteSetting(const CefString& requesting_url,
                                 const CefString& top_level_url,
                                 cef_content_setting_types_t content_type,
                                 CefRefPtr<CefValue> value) = 0;

  ///
  /// Returns the current value for |content_type| that applies for the
  /// specified URLs. If both URLs are empty the default value will be returned.
  /// Returns CEF_CONTENT_SETTING_VALUE_DEFAULT if no value is configured. Must
  /// be called on the browser process UI thread.
  ///
  /*--cef(optional_param=requesting_url,optional_param=top_level_url,
          default_retval=CEF_CONTENT_SETTING_VALUE_DEFAULT)--*/
  virtual cef_content_setting_values_t GetContentSetting(
      const CefString& requesting_url,
      const CefString& top_level_url,
      cef_content_setting_types_t content_type) = 0;

  ///
  /// Sets the current value for |content_type| for the specified URLs in the
  /// default scope. If both URLs are empty, and the context is not incognito,
  /// the default value will be set. Pass CEF_CONTENT_SETTING_VALUE_DEFAULT for
  /// |value| to use the default value for this content type.
  ///
  /// WARNING: Incorrect usage of this method may cause instability or security
  /// issues in Chromium. Make sure that you first understand the potential
  /// impact of any changes to |content_type| by reviewing the related source
  /// code in Chromium. For example, if you plan to modify
  /// CEF_CONTENT_SETTING_TYPE_POPUPS, first review and understand the usage of
  /// ContentSettingsType::POPUPS in Chromium:
  /// https://source.chromium.org/search?q=ContentSettingsType::POPUPS
  ///
  /*--cef(optional_param=requesting_url,optional_param=top_level_url)--*/
  virtual void SetContentSetting(const CefString& requesting_url,
                                 const CefString& top_level_url,
                                 cef_content_setting_types_t content_type,
                                 cef_content_setting_values_t value) = 0;

#if CEF_API_ADDED(13401)
  ///
  /// Add an observer for content and website setting changes. The observer will
  /// remain registered until the returned Registration object is destroyed.
  /// This method must be called on the browser process UI thread.
  ///
  /*--cef(added=13401)--*/
  virtual CefRefPtr<CefRegistration> AddSettingObserver(
      CefRefPtr<CefSettingObserver> observer) = 0;
#endif

  ///
  /// Sets the Chrome color scheme for all browsers that share this request
  /// context. |variant| values of SYSTEM, LIGHT and DARK change the underlying
  /// color mode (e.g. light vs dark). Other |variant| values determine how
  /// |user_color| will be applied in the current color mode. If |user_color| is
  /// transparent (0) the default color will be used.
  ///
  /*--cef()--*/
  virtual void SetChromeColorScheme(cef_color_variant_t variant,
                                    cef_color_t user_color) = 0;

  ///
  /// Returns the current Chrome color scheme mode (SYSTEM, LIGHT or DARK). Must
  /// be called on the browser process UI thread.
  ///
  /*--cef(default_retval=CEF_COLOR_VARIANT_SYSTEM)--*/
  virtual cef_color_variant_t GetChromeColorSchemeMode() = 0;

  ///
  /// Returns the current Chrome color scheme color, or transparent (0) for the
  /// default color. Must be called on the browser process UI thread.
  ///
  /*--cef(default_retval=0)--*/
  virtual cef_color_t GetChromeColorSchemeColor() = 0;

  ///
  /// Returns the current Chrome color scheme variant. Must be called on the
  /// browser process UI thread.
  ///
  /*--cef(default_retval=CEF_COLOR_VARIANT_SYSTEM)--*/
  virtual cef_color_variant_t GetChromeColorSchemeVariant() = 0;
};

#endif  // CEF_INCLUDE_CEF_REQUEST_CONTEXT_H_
