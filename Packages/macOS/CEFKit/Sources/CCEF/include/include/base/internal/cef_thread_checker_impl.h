// Copyright (c) 2025 Marshall A. Greenblatt. Portions copyright (c) 2011
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

// Do not include this header file directly. Use base/cef_thread_checker.h
// instead.

#ifndef CEF_INCLUDE_BASE_INTERNAL_CEF_THREAD_CHECKER_IMPL_H_
#define CEF_INCLUDE_BASE_INTERNAL_CEF_THREAD_CHECKER_IMPL_H_
#pragma once

#include "include/base/cef_lock.h"
#include "include/base/cef_platform_thread.h"

namespace base {
namespace cef_internal {

// Real implementation of ThreadChecker, for use in debug mode, or
// for temporary use in release mode (e.g. to CHECK on a threading issue
// seen only in the wild).
//
// Note: You should almost always use the ThreadChecker class to get the
// right version for your build configuration.
class ThreadCheckerImpl {
 public:
  ThreadCheckerImpl();
  ~ThreadCheckerImpl();

  bool CalledOnValidThread() const;

  // Changes the thread that is checked for in CalledOnValidThread.  This may
  // be useful when an object may be created on one thread and then used
  // exclusively on another thread.
  void DetachFromThread();

 private:
  void EnsureThreadIdAssigned() const;

  mutable base::Lock lock_;
  // This is mutable so that CalledOnValidThread can set it.
  // It's guarded by |lock_|.
  mutable PlatformThreadRef valid_thread_id_;
};

}  // namespace cef_internal
}  // namespace base

#endif  // CEF_INCLUDE_BASE_INTERNAL_CEF_THREAD_CHECKER_IMPL_H_
