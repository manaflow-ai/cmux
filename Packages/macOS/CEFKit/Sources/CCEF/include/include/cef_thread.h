// Copyright (c) 2016 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_THREAD_H_
#define CEF_INCLUDE_CEF_THREAD_H_
#pragma once

#include "include/cef_task.h"
#include "include/internal/cef_thread_internal.h"

///
/// A simple thread abstraction that establishes a message loop on a new thread.
/// The consumer uses CefTaskRunner to execute code on the thread's message
/// loop. The thread is terminated when the CefThread object is destroyed or
/// Stop() is called. All pending tasks queued on the thread's message loop will
/// run to completion before the thread is terminated. CreateThread() can be
/// called on any valid CEF thread in either the browser or render process. This
/// class should only be used for tasks that require a dedicated thread. In most
/// cases you can post tasks to an existing CEF thread instead of creating a new
/// one; see cef_task.h for details.
///
/*--cef(source=library)--*/
class CefThread : public CefBaseRefCounted {
 public:
  ///
  /// Create and start a new thread. This method does not block waiting for the
  /// thread to run initialization. |display_name| is the name that will be used
  /// to identify the thread. |priority| is the thread execution priority.
  /// |message_loop_type| indicates the set of asynchronous events that the
  /// thread can process. If |stoppable| is true the thread will stopped and
  /// joined on destruction or when Stop() is called; otherwise, the thread
  /// cannot be stopped and will be leaked on shutdown. On Windows the
  /// |com_init_mode| value specifies how COM will be initialized for the
  /// thread. If |com_init_mode| is set to COM_INIT_MODE_STA then
  /// |message_loop_type| must be set to ML_TYPE_UI.
  ///
  /*--cef(optional_param=display_name)--*/
  static CefRefPtr<CefThread> CreateThread(
      const CefString& display_name,
      cef_thread_priority_t priority,
      cef_message_loop_type_t message_loop_type,
      bool stoppable,
      cef_com_init_mode_t com_init_mode);

  ///
  /// Create and start a new thread with default/recommended values.
  /// |display_name| is the name that will be used to identify the thread.
  ///
  static CefRefPtr<CefThread> CreateThread(const CefString& display_name) {
    return CreateThread(display_name, TP_NORMAL, ML_TYPE_DEFAULT, true,
                        COM_INIT_MODE_NONE);
  }

  ///
  /// Returns the CefTaskRunner that will execute code on this thread's message
  /// loop. This method is safe to call from any thread.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefTaskRunner> GetTaskRunner() = 0;

  ///
  /// Returns the platform thread ID. It will return the same value after Stop()
  /// is called. This method is safe to call from any thread.
  ///
  /*--cef(default_retval=kInvalidPlatformThreadId)--*/
  virtual cef_platform_thread_id_t GetPlatformThreadId() = 0;

  ///
  /// Stop and join the thread. This method must be called from the same thread
  /// that called CreateThread(). Do not call this method if CreateThread() was
  /// called with a |stoppable| value of false.
  ///
  /*--cef()--*/
  virtual void Stop() = 0;

  ///
  /// Returns true if the thread is currently running. This method must be
  /// called from the same thread that called CreateThread().
  ///
  /*--cef()--*/
  virtual bool IsRunning() = 0;
};

#endif  // CEF_INCLUDE_CEF_THREAD_H_
