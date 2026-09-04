// Copyright (c) 2014 Marshall A. Greenblatt. Portions copyright (c) 2011
// Google Inc. All rights reserved.
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

// WARNING: You should *NOT* be using this class directly.  PlatformThread is
// the low-level platform-specific abstraction to the OS's threading interface.
// You should instead be using a message-loop driven Thread, see thread.h.

#ifndef CEF_INCLUDE_BASE_CEF_PLATFORM_THREAD_H_
#define CEF_INCLUDE_BASE_CEF_PLATFORM_THREAD_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/threading/platform_thread.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include "include/base/cef_build.h"
#include "include/internal/cef_thread_internal.h"

namespace base {

///
/// Used for logging. Always an integer value.
///
typedef cef_platform_thread_id_t PlatformThreadId;

///
/// Used for thread checking and debugging.
/// Meant to be as fast as possible.
/// These are produced by PlatformThread::CurrentRef(), and used to later
/// check if we are on the same thread or not by using ==. These are safe
/// to copy between threads, but can't be copied to another process as they
/// have no meaning there. Also, the internal identifier can be re-used
/// after a thread dies, so a PlatformThreadRef cannot be reliably used
/// to distinguish a new thread from an old, dead thread.
///
class PlatformThreadRef {
 public:
  typedef cef_platform_thread_handle_t RefType;

  PlatformThreadRef() : id_(0) {}

  explicit PlatformThreadRef(RefType id) : id_(id) {}

  bool operator==(PlatformThreadRef other) const { return id_ == other.id_; }

  bool is_null() const { return id_ == 0; }

 private:
  RefType id_;
};

///
/// A namespace for low-level thread functions.
/// Chromium uses a class with static methods but CEF uses an actual namespace
/// to avoid linker problems with the sandbox libaries on Windows.
///
namespace PlatformThread {

///
/// Gets the current thread id, which may be useful for logging purposes.
///
inline PlatformThreadId CurrentId() {
  return cef_get_current_platform_thread_id();
}

///
/// Gets the current thread reference, which can be used to check if
/// we're on the right thread quickly.
///
inline PlatformThreadRef CurrentRef() {
  return PlatformThreadRef(cef_get_current_platform_thread_handle());
}

}  // namespace PlatformThread

}  // namespace base

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_PLATFORM_THREAD_H_
