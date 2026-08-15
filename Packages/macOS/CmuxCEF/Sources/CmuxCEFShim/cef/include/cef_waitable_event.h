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

#ifndef CEF_INCLUDE_CEF_WAITABLE_EVENT_H_
#define CEF_INCLUDE_CEF_WAITABLE_EVENT_H_
#pragma once

#include "include/cef_base.h"

///
/// WaitableEvent is a thread synchronization tool that allows one thread to
/// wait for another thread to finish some work. This is equivalent to using a
/// Lock+ConditionVariable to protect a simple boolean value. However, using
/// WaitableEvent in conjunction with a Lock to wait for a more complex state
/// change (e.g., for an item to be added to a queue) is not recommended. In
/// that case consider using a ConditionVariable instead of a WaitableEvent. It
/// is safe to create and/or signal a WaitableEvent from any thread. Blocking on
/// a WaitableEvent by calling the *Wait() methods is not allowed on the browser
/// process UI or IO threads.
///
/*--cef(source=library)--*/
class CefWaitableEvent : public CefBaseRefCounted {
 public:
  ///
  /// Create a new waitable event. If |automatic_reset| is true then the event
  /// state is automatically reset to un-signaled after a single waiting thread
  /// has been released; otherwise, the state remains signaled until Reset() is
  /// called manually. If |initially_signaled| is true then the event will start
  /// in the signaled state.
  ///
  /*--cef()--*/
  static CefRefPtr<CefWaitableEvent> CreateWaitableEvent(
      bool automatic_reset,
      bool initially_signaled);

  ///
  /// Put the event in the un-signaled state.
  ///
  /*--cef()--*/
  virtual void Reset() = 0;

  ///
  /// Put the event in the signaled state. This causes any thread blocked on
  /// Wait to be woken up.
  ///
  /*--cef()--*/
  virtual void Signal() = 0;

  ///
  /// Returns true if the event is in the signaled state, else false. If the
  /// event was created with |automatic_reset| set to true then calling this
  /// method will also cause a reset.
  ///
  /*--cef()--*/
  virtual bool IsSignaled() = 0;

  ///
  /// Wait indefinitely for the event to be signaled. This method will not
  /// return until after the call to Signal() has completed. This method cannot
  /// be called on the browser process UI or IO threads.
  ///
  /*--cef()--*/
  virtual void Wait() = 0;

  ///
  /// Wait up to |max_ms| milliseconds for the event to be signaled. Returns
  /// true if the event was signaled. A return value of false does not
  /// necessarily mean that |max_ms| was exceeded. This method will not return
  /// until after the call to Signal() has completed. This method cannot be
  /// called on the browser process UI or IO threads.
  ///
  /*--cef()--*/
  virtual bool TimedWait(int64_t max_ms) = 0;
};

#endif  // CEF_INCLUDE_CEF_WAITABLE_EVENT_H_
