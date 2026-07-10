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

#ifndef CEF_INCLUDE_CEF_BROWSER_PROCESS_HANDLER_H_
#define CEF_INCLUDE_CEF_BROWSER_PROCESS_HANDLER_H_
#pragma once

#include "include/cef_base.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_preference.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_values.h"

///
/// Class used to implement browser process callbacks. The methods of this class
/// will be called on the browser process main thread unless otherwise
/// indicated.
///
/*--cef(source=client,no_debugct_check)--*/
class CefBrowserProcessHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// Provides an opportunity to register custom preferences prior to
  /// global and request context initialization.
  ///
  /// If |type| is CEF_PREFERENCES_TYPE_GLOBAL the registered preferences can be
  /// accessed via CefPreferenceManager::GetGlobalPreferences after
  /// OnContextInitialized is called. Global preferences are registered a single
  /// time at application startup. See related cef_settings_t.cache_path
  /// configuration.
  ///
  /// If |type| is CEF_PREFERENCES_TYPE_REQUEST_CONTEXT the preferences can be
  /// accessed via the CefRequestContext after
  /// CefRequestContextHandler::OnRequestContextInitialized is called. Request
  /// context preferences are registered each time a new CefRequestContext is
  /// created. It is intended but not required that all request contexts have
  /// the same registered preferences. See related
  /// cef_request_context_settings_t.cache_path configuration.
  ///
  /// Do not keep a reference to the |registrar| object. This method is called
  /// on the browser process UI thread.
  ///
  /*--cef()--*/
  virtual void OnRegisterCustomPreferences(
      cef_preferences_type_t type,
      CefRawPtr<CefPreferenceRegistrar> registrar) {}

  ///
  /// Called on the browser process UI thread immediately after the CEF context
  /// has been initialized.
  ///
  /*--cef()--*/
  virtual void OnContextInitialized() {}

  ///
  /// Called before a child process is launched. Will be called on the browser
  /// process UI thread when launching a render process and on the browser
  /// process IO thread when launching a GPU process. Provides an opportunity to
  /// modify the child process command line. Do not keep a reference to
  /// |command_line| outside of this method.
  ///
  /*--cef()--*/
  virtual void OnBeforeChildProcessLaunch(
      CefRefPtr<CefCommandLine> command_line) {}

  ///
  /// Implement this method to provide app-specific behavior when an already
  /// running app is relaunched with the same CefSettings.root_cache_path value.
  /// For example, activate an existing app window or create a new app window.
  /// |command_line| will be read-only. Do not keep a reference to
  /// |command_line| outside of this method. Return true if the relaunch is
  /// handled or false for default relaunch behavior. Default behavior will
  /// create a new default styled Chrome window.
  ///
  /// To avoid cache corruption only a single app instance is allowed to run for
  /// a given CefSettings.root_cache_path value. On relaunch the app checks a
  /// process singleton lock and then forwards the new launch arguments to the
  /// already running app process before exiting early. Client apps should
  /// therefore check the CefInitialize() return value for early exit before
  /// proceeding.
  ///
  /// This method will be called on the browser process UI thread.
  ///
  /*--cef(optional_param=current_directory)--*/
  virtual bool OnAlreadyRunningAppRelaunch(
      CefRefPtr<CefCommandLine> command_line,
      const CefString& current_directory) {
    return false;
  }

  ///
  /// Called from any thread when work has been scheduled for the browser
  /// process main (UI) thread. This callback is used in combination with
  /// cef_settings_t.external_message_pump and CefDoMessageLoopWork() in cases
  /// where the CEF message loop must be integrated into an existing application
  /// message loop (see additional comments and warnings on
  /// CefDoMessageLoopWork). This callback should schedule a
  /// CefDoMessageLoopWork() call to happen on the main (UI) thread. |delay_ms|
  /// is the requested delay in milliseconds. If |delay_ms| is <= 0 then the
  /// call should happen reasonably soon. If |delay_ms| is > 0 then the call
  /// should be scheduled to happen after the specified delay and any currently
  /// pending scheduled call should be cancelled.
  ///
  /*--cef()--*/
  virtual void OnScheduleMessagePumpWork(int64_t delay_ms) {}

  ///
  /// Return the default client for use with a newly created browser window
  /// (CefBrowser object). If null is returned the CefBrowser will be unmanaged
  /// (no callbacks will be executed for that CefBrowser) and application
  /// shutdown will be blocked until the browser window is closed manually. This
  /// method is currently only used with Chrome style when creating new browser
  /// windows via Chrome UI.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefClient> GetDefaultClient() { return nullptr; }

  ///
  /// Return the default handler for use with a new user or incognito profile
  /// (CefRequestContext object). If null is returned the CefRequestContext will
  /// be unmanaged (no callbacks will be executed for that CefRequestContext).
  /// This method is currently only used with Chrome style when creating new
  /// browser windows via Chrome UI.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefRequestContextHandler>
  GetDefaultRequestContextHandler() {
    return nullptr;
  }
};

#endif  // CEF_INCLUDE_CEF_BROWSER_PROCESS_HANDLER_H_
