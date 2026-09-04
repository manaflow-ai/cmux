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

#ifndef CEF_INCLUDE_BASE_CEF_ATOMIC_FLAG_H_
#define CEF_INCLUDE_BASE_CEF_ATOMIC_FLAG_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/synchronization/atomic_flag.h"

#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include <stdint.h>

#include <atomic>

#include "include/base/cef_thread_checker.h"

namespace base {

///
/// A flag that can safely be set from one thread and read from other threads.
///
/// This class IS NOT intended for synchronization between threads.
///
class AtomicFlag {
 public:
  AtomicFlag();

  AtomicFlag(const AtomicFlag&) = delete;
  AtomicFlag& operator=(const AtomicFlag&) = delete;

  ~AtomicFlag();

  ///
  /// Set the flag. Must always be called from the same thread.
  ///
  void Set();

  ///
  /// Returns true iff the flag was set. If this returns true, the current
  /// thread is guaranteed to be synchronized with all memory operations on the
  /// thread which invoked Set() up until at least the first call to Set() on
  /// it.
  ///
  bool IsSet() const {
    // Inline here: this has a measurable performance impact on base::WeakPtr.
    return flag_.load(std::memory_order_acquire) != 0;
  }

  ///
  /// Resets the flag. Be careful when using this: callers might not expect
  /// IsSet() to return false after returning true once.
  ///
  void UnsafeResetForTesting();

 private:
  std::atomic<uint_fast8_t> flag_{0};
  base::ThreadChecker set_thread_checker_;
};

}  // namespace base

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_ATOMIC_FLAG_H_
