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

#ifndef CEF_INCLUDE_BASE_CEF_LOCK_H_
#define CEF_INCLUDE_BASE_CEF_LOCK_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/synchronization/lock.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include "include/base/cef_logging.h"
#include "include/base/cef_platform_thread.h"
#include "include/base/internal/cef_lock_impl.h"

namespace base {
namespace cef_internal {

///
/// A convenient wrapper for an OS specific critical section.  The only real
/// intelligence in this class is in debug mode for the support for the
/// AssertAcquired() method.
///
class Lock {
 public:
#if !DCHECK_IS_ON()  // Optimized wrapper implementation
  Lock() : lock_() {}

  Lock(const Lock&) = delete;
  Lock& operator=(const Lock&) = delete;

  ~Lock() {}
  void Acquire() { lock_.Lock(); }
  void Release() { lock_.Unlock(); }

  ///
  /// If the lock is not held, take it and return true. If the lock is already
  /// held by another thread, immediately return false. This must not be called
  /// by a thread already holding the lock (what happens is undefined and an
  /// assertion may fail).
  ///
  bool Try() { return lock_.Try(); }

  // Null implementation if not debug.
  void AssertAcquired() const {}
#else
  Lock();
  ~Lock();

  // NOTE: Although windows critical sections support recursive locks, we do not
  // allow this, and we will commonly fire a DCHECK() if a thread attempts to
  // acquire the lock a second time (while already holding it).
  void Acquire() {
    lock_.Lock();
    CheckUnheldAndMark();
  }
  void Release() {
    CheckHeldAndUnmark();
    lock_.Unlock();
  }

  bool Try() {
    bool rv = lock_.Try();
    if (rv) {
      CheckUnheldAndMark();
    }
    return rv;
  }

  void AssertAcquired() const;
#endif  // !DCHECK_IS_ON()

 private:
#if DCHECK_IS_ON()
  // Members and routines taking care of locks assertions.
  // Note that this checks for recursive locks and allows them
  // if the variable is set.  This is allowed by the underlying implementation
  // on windows but not on Posix, so we're doing unneeded checks on Posix.
  // It's worth it to share the code.
  void CheckHeldAndUnmark();
  void CheckUnheldAndMark();

  // All private data is implicitly protected by lock_.
  // Be VERY careful to only access members under that lock.
  base::PlatformThreadRef owning_thread_ref_;
#endif  // DCHECK_IS_ON()

  // Platform specific underlying lock implementation.
  LockImpl lock_;
};

///
/// A helper class that acquires the given Lock while the AutoLock is in scope.
///
class AutoLock {
 public:
  struct AlreadyAcquired {};

  explicit AutoLock(Lock& lock) : lock_(lock) { lock_.Acquire(); }

  AutoLock(Lock& lock, const AlreadyAcquired&) : lock_(lock) {
    lock_.AssertAcquired();
  }

  AutoLock(const AutoLock&) = delete;
  AutoLock& operator=(const AutoLock&) = delete;

  ~AutoLock() {
    lock_.AssertAcquired();
    lock_.Release();
  }

 private:
  Lock& lock_;
};

///
/// AutoUnlock is a helper that will Release() the |lock| argument in the
/// constructor, and re-Acquire() it in the destructor.
///
class AutoUnlock {
 public:
  explicit AutoUnlock(Lock& lock) : lock_(lock) {
    // We require our caller to have the lock.
    lock_.AssertAcquired();
    lock_.Release();
  }

  AutoUnlock(const AutoUnlock&) = delete;
  AutoUnlock& operator=(const AutoUnlock&) = delete;

  ~AutoUnlock() { lock_.Acquire(); }

 private:
  Lock& lock_;
};

}  // namespace cef_internal

// Implement classes in the cef_internal namespace and then expose them to the
// base namespace. This avoids conflicts with the base.lib implementation when
// linking sandbox support on Windows.
using cef_internal::AutoLock;
using cef_internal::AutoUnlock;
using cef_internal::Lock;

}  // namespace base

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_LOCK_H_
