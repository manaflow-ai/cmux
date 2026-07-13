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

#ifndef CEF_INCLUDE_CEF_BASE_H_
#define CEF_INCLUDE_CEF_BASE_H_
#pragma once

#if !defined(GENERATING_CEF_API_HASH)
#include "include/base/cef_build.h"
#endif

#include "include/base/cef_atomic_ref_count.h"
#include "include/base/cef_macros.h"

// Bring in common C++ type definitions used by CEF consumers.
#include "include/internal/cef_ptr.h"
#include "include/internal/cef_time_wrappers.h"
#include "include/internal/cef_types_wrappers.h"
#if defined(OS_WIN)
#include "include/internal/cef_win.h"
#elif defined(OS_MAC)
#include "include/internal/cef_mac.h"
#elif defined(OS_LINUX)
#include "include/internal/cef_linux.h"
#endif

///
/// All ref-counted framework classes must extend this class.
///
class CefBaseRefCounted {
 public:
  ///
  /// Called to increment the reference count for the object. Should be called
  /// for every new copy of a pointer to a given object.
  ///
  virtual void AddRef() const = 0;

  ///
  /// Called to decrement the reference count for the object. Returns true if
  /// the reference count is 0, in which case the object should self-delete.
  ///
  virtual bool Release() const = 0;

  ///
  /// Returns true if the reference count is 1.
  ///
  virtual bool HasOneRef() const = 0;

  ///
  /// Returns true if the reference count is at least 1.
  ///
  virtual bool HasAtLeastOneRef() const = 0;

 protected:
  virtual ~CefBaseRefCounted() {}
};

///
/// All scoped framework classes must extend this class.
///
class CefBaseScoped {
 public:
  virtual ~CefBaseScoped() {}
};

///
/// Class that implements atomic reference counting.
///
class CefRefCount {
 public:
  CefRefCount() = default;

  CefRefCount(const CefRefCount&) = delete;
  CefRefCount& operator=(const CefRefCount&) = delete;

  ///
  /// Increment the reference count.
  ///
  void AddRef() const { ref_count_.Increment(); }

  ///
  /// Decrement the reference count. Returns true if the reference count is 0.
  ///
  bool Release() const { return !ref_count_.Decrement(); }

  ///
  /// Returns true if the reference count is 1.
  ///
  bool HasOneRef() const { return ref_count_.IsOne(); }

  ///
  /// Returns true if the reference count is at least 1.
  ///
  bool HasAtLeastOneRef() const { return !ref_count_.IsZero(); }

  ///
  /// Returns the current reference count (with no barriers). This is subtle,
  /// and should be used only for debugging.
  ///
  int SubtleRefCountForDebug() const {
    return ref_count_.SubtleRefCountForDebug();
  }

 private:
  mutable base::AtomicRefCount ref_count_{0};
};

///
/// Macro that provides a reference counting implementation for classes
/// extending CefBase.
///
#define IMPLEMENT_REFCOUNTING(ClassName)          \
 public:                                          \
  void AddRef() const override {                  \
    ref_count_.AddRef();                          \
  }                                               \
  bool Release() const override {                 \
    if (ref_count_.Release()) {                   \
      delete static_cast<const ClassName*>(this); \
      return true;                                \
    }                                             \
    return false;                                 \
  }                                               \
  bool HasOneRef() const override {               \
    return ref_count_.HasOneRef();                \
  }                                               \
  bool HasAtLeastOneRef() const override {        \
    return ref_count_.HasAtLeastOneRef();         \
  }                                               \
                                                  \
 private:                                         \
  CefRefCount ref_count_

#endif  // CEF_INCLUDE_CEF_BASE_H_
