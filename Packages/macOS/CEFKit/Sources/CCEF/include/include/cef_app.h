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

#ifndef CEF_INCLUDE_CEF_APP_H_
#define CEF_INCLUDE_CEF_APP_H_
#pragma once

#include "include/cef_base.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_command_line.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_resource_bundle_handler.h"
#include "include/cef_scheme.h"

class CefApp;

///
/// This function should be called from the application entry point function to
/// execute a secondary process. It can be used to run secondary processes from
/// the browser client executable (default behavior) or from a separate
/// executable specified by the cef_settings_t.browser_subprocess_path value. If
/// called for the browser process (identified by no "type" command-line value)
/// it will return immediately with a value of -1. If called for a recognized
/// secondary process it will block until the process should exit and then
/// return the process exit code. The |application| parameter may be empty. The
/// |windows_sandbox_info| parameter is only used on Windows and may be NULL
/// (see cef_sandbox_win.h for details).
///
/*--cef(api_hash_check,no_stack_protector,optional_param=application,
        optional_param=windows_sandbox_info)--*/
int CefExecuteProcess(const CefMainArgs& args,
                      CefRefPtr<CefApp> application,
                      void* windows_sandbox_info);

///
/// This function should be called on the main application thread to initialize
/// the CEF browser process. The |application| parameter may be empty. Returns
/// true if initialization succeeds. Returns false if initialization fails or if
/// early exit is desired (for example, due to process singleton relaunch
/// behavior). If this function returns false then the application should exit
/// immediately without calling any other CEF functions except, optionally,
/// CefGetExitCode. The |windows_sandbox_info| parameter is only used on Windows
/// and may be NULL (see cef_sandbox_win.h for details).
///
/*--cef(api_hash_check,optional_param=application,
        optional_param=windows_sandbox_info)--*/
bool CefInitialize(const CefMainArgs& args,
                   const CefSettings& settings,
                   CefRefPtr<CefApp> application,
                   void* windows_sandbox_info);

///
/// This function can optionally be called on the main application thread after
/// CefInitialize to retrieve the initialization exit code. When CefInitialize
/// returns true the exit code will be 0 (CEF_RESULT_CODE_NORMAL_EXIT).
/// Otherwise, see cef_resultcode_t for possible exit code values including
/// browser process initialization errors and normal early exit conditions (such
/// as CEF_RESULT_CODE_NORMAL_EXIT_PROCESS_NOTIFIED for process singleton
/// relaunch behavior).
///
/*--cef()--*/
int CefGetExitCode();

///
/// This function should be called on the main application thread to shut down
/// the CEF browser process before the application exits. Do not call any
/// other CEF functions after calling this function.
///
/*--cef()--*/
void CefShutdown();

///
/// Perform a single iteration of CEF message loop processing. This function is
/// provided for cases where the CEF message loop must be integrated into an
/// existing application message loop. Use of this function is not recommended
/// for most users; use either the CefRunMessageLoop() function or
/// cef_settings_t.multi_threaded_message_loop if possible. When using this
/// function care must be taken to balance performance against excessive CPU
/// usage. It is recommended to enable the cef_settings_t.external_message_pump
/// option when using this function so that
/// CefBrowserProcessHandler::OnScheduleMessagePumpWork() callbacks can
/// facilitate the scheduling process. This function should only be called on
/// the main application thread and only if CefInitialize() is called with a
/// cef_settings_t.multi_threaded_message_loop value of false. This function
/// will not block.
///
/*--cef()--*/
void CefDoMessageLoopWork();

///
/// Run the CEF message loop. Use this function instead of an application-
/// provided message loop to get the best balance between performance and CPU
/// usage. This function should only be called on the main application thread
/// and only if CefInitialize() is called with a
/// cef_settings_t.multi_threaded_message_loop value of false. This function
/// will block until a quit message is received by the system.
///
/*--cef()--*/
void CefRunMessageLoop();

///
/// Quit the CEF message loop that was started by calling CefRunMessageLoop().
/// This function should only be called on the main application thread and only
/// if CefRunMessageLoop() was used.
///
/*--cef()--*/
void CefQuitMessageLoop();

#if CEF_API_ADDED(14100)
///
/// Set to true before calling OS APIs on the CEF UI thread that will enter a
/// native message loop (see usage restrictions below). Set to false after
/// exiting the native message loop. On Windows, use the CefSetOSModalLoop
/// function instead in cases like native top menus where resize of the browser
/// content is not required, or in cases like printer APIs where reentrancy
/// safety cannot be guaranteed.
///
/// Nested processing of Chromium tasks is disabled by default because common
/// controls and/or printer functions may use nested native message loops that
/// lead to unplanned reentrancy. This function re-enables nested processing in
/// the scope of an upcoming native message loop. It must only be used in cases
/// where the stack is reentrancy safe and processing nestable tasks is
/// explicitly safe. Do not use in cases (like the printer example) where an OS
/// API may experience unplanned reentrancy as a result of a new task executing
/// immediately.
///
/// For instance,
/// - The UI thread is running a message loop.
/// - It receives a task #1 and executes it.
/// - The task #1 implicitly starts a nested message loop. For example, via
///   Windows APIs such as MessageBox or GetSaveFileName, or default handling
///   of a user-initiated drag/resize operation (e.g. DefWindowProc handling of
///   WM_SYSCOMMAND for SC_MOVE/SC_SIZE).
/// - The UI thread receives a task #2 before or while in this second message
///   loop.
/// - With NestableTasksAllowed set to true, the task #2 will run right away.
///   Otherwise, it will be executed right after task #1 completes at "thread
///   message loop level".
///
/*--cef(added=14100)--*/
void CefSetNestableTasksAllowed(bool allowed);

#ifdef __cplusplus
///
/// Scoped helper for calling CefSetNestableTasksAllowed.
///
class CefScopedSetNestableTasksAllowed final {
 public:
  CefScopedSetNestableTasksAllowed() { CefSetNestableTasksAllowed(true); }
  ~CefScopedSetNestableTasksAllowed() { CefSetNestableTasksAllowed(false); }
};
#endif  // __cplusplus
#endif

///
/// Implement this interface to provide handler implementations. Methods will be
/// called by the process and/or thread indicated.
///
/*--cef(source=client,no_debugct_check)--*/
class CefApp : public virtual CefBaseRefCounted {
 public:
  ///
  /// Provides an opportunity to view and/or modify command-line arguments
  /// before processing by CEF and Chromium. The |process_type| value will be
  /// empty for the browser process. Do not keep a reference to the
  /// CefCommandLine object passed to this method. The
  /// cef_settings_t.command_line_args_disabled value can be used to start with
  /// an empty command-line object. Any values specified in CefSettings that
  /// equate to command-line arguments will be set before this method is called.
  /// Be cautious when using this method to modify command-line arguments for
  /// non-browser processes as this may result in undefined behavior including
  /// crashes.
  ///
  /*--cef(optional_param=process_type)--*/
  virtual void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) {}

  ///
  /// Provides an opportunity to register custom schemes. Do not keep a
  /// reference to the |registrar| object. This method is called on the main
  /// thread for each process and the registered schemes should be the same
  /// across all processes.
  ///
  /*--cef()--*/
  virtual void OnRegisterCustomSchemes(
      CefRawPtr<CefSchemeRegistrar> registrar) {}

  ///
  /// Return the handler for resource bundle events. If no handler is returned
  /// resources will be loaded from pack files. This method is called by the
  /// browser and render processes on multiple threads.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefResourceBundleHandler> GetResourceBundleHandler() {
    return nullptr;
  }

  ///
  /// Return the handler for functionality specific to the browser process. This
  /// method is called on multiple threads in the browser process.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() {
    return nullptr;
  }

  ///
  /// Return the handler for functionality specific to the render process. This
  /// method is called on the render process main thread.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() {
    return nullptr;
  }
};

#endif  // CEF_INCLUDE_CEF_APP_H_
