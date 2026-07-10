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

// This is a low level implementation of atomic semantics for reference
// counting.  Please use cef_ref_counted.h directly instead.
//
// The Chromium implementation includes annotations to avoid some false
// positives when using data race detection tools. Annotations are not
// currently supported by the CEF implementation.

#ifndef CEF_INCLUDE_BASE_CEF_ATOMIC_REF_COUNT_H_
#define CEF_INCLUDE_BASE_CEF_ATOMIC_REF_COUNT_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/atomic_ref_count.h"

#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include <atomic>

namespace base {

class AtomicRefCount {
 public:
  constexpr AtomicRefCount() : ref_count_(0) {}
  explicit constexpr AtomicRefCount(int initial_value)
      : ref_count_(initial_value) {}

  ///
  /// Increment a reference count.
  /// Returns the previous value of the count.
  ///
  int Increment() { return Increment(1); }

  ///
  /// Increment a reference count by "increment", which must exceed 0.
  /// Returns the previous value of the count.
  ///
  int Increment(int increment) {
    return ref_count_.fetch_add(increment, std::memory_order_relaxed);
  }

  ///
  /// Decrement a reference count, and return whether the result is non-zero.
  /// Insert barriers to ensure that state written before the reference count
  /// became zero will be visible to a thread that has just made the count zero.
  ///
  bool Decrement() {
    // TODO(jbroman): Technically this doesn't need to be an acquire operation
    // unless the result is 1 (i.e., the ref count did indeed reach zero).
    // However, there are toolchain issues that make that not work as well at
    // present (notably TSAN doesn't like it).
    return ref_count_.fetch_sub(1, std::memory_order_acq_rel) != 1;
  }

  ///
  /// Return whether the reference count is one.  If the reference count is used
  /// in the conventional way, a refrerence count of 1 implies that the current
  /// thread owns the reference and no other thread shares it.  This call
  /// performs the test for a reference count of one, and performs the memory
  /// barrier needed for the owning thread to act on the object, knowing that it
  /// has exclusive access to the object.
  ///
  bool IsOne() const { return ref_count_.load(std::memory_order_acquire) == 1; }

  ///
  /// Return whether the reference count is zero.  With conventional object
  /// referencing counting, the object will be destroyed, so the reference count
  /// should never be zero.  Hence this is generally used for a debug check.
  ///
  bool IsZero() const {
    return ref_count_.load(std::memory_order_acquire) == 0;
  }

  ///
  /// Returns the current reference count (with no barriers). This is subtle,
  /// and should be used only for debugging.
  ///
  int SubtleRefCountForDebug() const {
    return ref_count_.load(std::memory_order_relaxed);
  }

 private:
  std::atomic_int ref_count_;
};

}  // namespace base

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_ATOMIC_REF_COUNT_H_
