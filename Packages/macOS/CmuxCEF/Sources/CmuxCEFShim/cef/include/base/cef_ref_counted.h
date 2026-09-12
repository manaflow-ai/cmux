// Copyright (c) 2014 Marshall A. Greenblatt. Portions copyright (c) 2012
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
//

#ifndef CEF_INCLUDE_BASE_CEF_REF_COUNTED_H_
#define CEF_INCLUDE_BASE_CEF_REF_COUNTED_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/memory/ref_counted.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include <stddef.h>

#include <concepts>
#include <limits>
#include <utility>

#include "include/base/cef_atomic_ref_count.h"
#include "include/base/cef_build.h"
#include "include/base/cef_compiler_specific.h"
#include "include/base/cef_logging.h"
#include "include/base/cef_scoped_refptr.h"
#include "include/base/cef_thread_checker.h"

namespace base {
namespace cef_subtle {

class RefCountedBase {
 public:
  bool HasOneRef() const { return ref_count_ == 1; }
  bool HasAtLeastOneRef() const { return ref_count_ >= 1; }

 protected:
  explicit RefCountedBase(StartRefCountFromZeroTag) {
#if DCHECK_IS_ON()
    thread_checker_.DetachFromThread();
#endif
  }

  explicit RefCountedBase(StartRefCountFromOneTag) : ref_count_(1) {
#if DCHECK_IS_ON()
    needs_adopt_ref_ = true;
    thread_checker_.DetachFromThread();
#endif
  }

  RefCountedBase(const RefCountedBase&) = delete;
  RefCountedBase& operator=(const RefCountedBase&) = delete;

  ~RefCountedBase() {
#if DCHECK_IS_ON()
    DCHECK(in_dtor_) << "RefCounted object deleted without calling Release()";
#endif
  }

  void AddRef() const {
#if DCHECK_IS_ON()
    DCHECK(!in_dtor_);
    DCHECK(!needs_adopt_ref_)
        << "This RefCounted object is created with non-zero reference count."
        << " The first reference to such a object has to be made by AdoptRef or"
        << " MakeRefCounted.";
    if (ref_count_ >= 1) {
      DCHECK(CalledOnValidThread());
    }
#endif

    AddRefImpl();
  }

  // Returns true if the object should self-delete.
  bool Release() const {
    ReleaseImpl();

#if DCHECK_IS_ON()
    DCHECK(!in_dtor_);
    if (ref_count_ == 0) {
      in_dtor_ = true;
    }

    if (ref_count_ >= 1) {
      DCHECK(CalledOnValidThread());
    }
    if (ref_count_ == 1) {
      thread_checker_.DetachFromThread();
    }
#endif

    return ref_count_ == 0;
  }

  // Returns true if it is safe to read or write the object, from a thread
  // safety standpoint. Should be DCHECK'd from the methods of RefCounted
  // classes if there is a danger of objects being shared across threads.
  //
  // This produces fewer false positives than adding a separate ThreadChecker
  // into the subclass, because it automatically detaches from the thread when
  // the reference count is 1 (and never fails if there is only one reference).
  //
  // This means unlike a separate ThreadChecker, it will permit a singly
  // referenced object to be passed between threads (not holding a reference on
  // the sending thread), but will trap if the sending thread holds onto a
  // reference, or if the object is accessed from multiple threads
  // simultaneously.
  bool IsOnValidThread() const {
#if DCHECK_IS_ON()
    return ref_count_ <= 1 || CalledOnValidThread();
#else
    return true;
#endif
  }

 private:
  template <typename U>
  friend scoped_refptr<U> base::AdoptRef(U*);

  void Adopted() const {
#if DCHECK_IS_ON()
    DCHECK(needs_adopt_ref_);
    needs_adopt_ref_ = false;
#endif
  }

#if defined(ARCH_CPU_64_BITS)
  void AddRefImpl() const;
  void ReleaseImpl() const;
#else
  void AddRefImpl() const { ++ref_count_; }
  void ReleaseImpl() const { --ref_count_; }
#endif

#if DCHECK_IS_ON()
  bool CalledOnValidThread() const;
#endif

  mutable uint32_t ref_count_ = 0;
  static_assert(std::is_unsigned_v<decltype(ref_count_)>,
                "ref_count_ must be an unsigned type.");

#if DCHECK_IS_ON()
  mutable bool needs_adopt_ref_ = false;
  mutable bool in_dtor_ = false;
  mutable ThreadChecker thread_checker_;
#endif
};

class RefCountedThreadSafeBase {
 public:
  bool HasOneRef() const;
  bool HasAtLeastOneRef() const;

 protected:
  explicit constexpr RefCountedThreadSafeBase(StartRefCountFromZeroTag) {}
  explicit constexpr RefCountedThreadSafeBase(StartRefCountFromOneTag)
      : ref_count_(1) {
#if DCHECK_IS_ON()
    needs_adopt_ref_ = true;
#endif
  }

  RefCountedThreadSafeBase(const RefCountedThreadSafeBase&) = delete;
  RefCountedThreadSafeBase& operator=(const RefCountedThreadSafeBase&) = delete;

#if DCHECK_IS_ON()
  ~RefCountedThreadSafeBase();
#else
  ~RefCountedThreadSafeBase() = default;
#endif

// Release and AddRef are suitable for inlining on X86 because they generate
// very small code sequences.
//
// ARM64 devices supporting ARMv8.1-A atomic instructions generate very little
// code, e.g. fetch_add() with acquire ordering is a single instruction (ldadd),
// vs LL/SC in previous ARM architectures. Inline it there as well.
//
// On other platforms (e.g. ARM), it causes a size regression and is probably
// not worth it.
#if defined(ARCH_CPU_X86_FAMILY) || defined(__ARM_FEATURE_ATOMICS)
  // Returns true if the object should self-delete.
  bool Release() const { return ReleaseImpl(); }
  void AddRef() const { AddRefImpl(); }
  void AddRefWithCheck() const { AddRefWithCheckImpl(); }
#else
  // Returns true if the object should self-delete.
  bool Release() const;
  void AddRef() const;
  void AddRefWithCheck() const;
#endif

 private:
  template <typename U>
  friend scoped_refptr<U> base::AdoptRef(U*);

  void Adopted() const {
#if DCHECK_IS_ON()
    DCHECK(needs_adopt_ref_);
    needs_adopt_ref_ = false;
#endif
  }

  ALWAYS_INLINE void AddRefImpl() const {
#if DCHECK_IS_ON()
    DCHECK(!in_dtor_);
    // This RefCounted object is created with non-zero reference count.
    // The first reference to such a object has to be made by AdoptRef or
    // MakeRefCounted.
    DCHECK(!needs_adopt_ref_);
#endif
    CHECK(ref_count_.Increment() != std::numeric_limits<int>::max());
  }

  ALWAYS_INLINE void AddRefWithCheckImpl() const {
#if DCHECK_IS_ON()
    DCHECK(!in_dtor_);
    // This RefCounted object is created with non-zero reference count.
    // The first reference to such a object has to be made by AdoptRef or
    // MakeRefCounted.
    DCHECK(!needs_adopt_ref_);
#endif
    int pre_increment_count = ref_count_.Increment();
    CHECK(pre_increment_count > 0);
    CHECK(pre_increment_count != std::numeric_limits<int>::max());
  }

  ALWAYS_INLINE bool ReleaseImpl() const {
#if DCHECK_IS_ON()
    DCHECK(!in_dtor_);
    DCHECK(!ref_count_.IsZero());
#endif
    if (!ref_count_.Decrement()) {
#if DCHECK_IS_ON()
      in_dtor_ = true;
#endif
      return true;
    }
    return false;
  }

  mutable AtomicRefCount ref_count_{0};
#if DCHECK_IS_ON()
  mutable bool needs_adopt_ref_ = false;
  mutable bool in_dtor_ = false;
#endif
};

// ScopedAllowCrossThreadRefCountAccess disables the check documented on
// RefCounted below for rare pre-existing use cases where thread-safety was
// guaranteed through other means (e.g. explicit sequencing of calls across
// execution threads when bouncing between threads in order). New callers
// should refrain from using this (callsites handling thread-safety through
// locks should use RefCountedThreadSafe per the overhead of its atomics being
// negligible compared to locks anyways and callsites doing explicit sequencing
// should properly std::move() the ref to avoid hitting this check).
// TODO(tzik): Cleanup existing use cases and remove
// ScopedAllowCrossThreadRefCountAccess.
class ScopedAllowCrossThreadRefCountAccess final {
 public:
#if DCHECK_IS_ON()
  ScopedAllowCrossThreadRefCountAccess();
  ~ScopedAllowCrossThreadRefCountAccess();
#else
  ScopedAllowCrossThreadRefCountAccess() {}
  ~ScopedAllowCrossThreadRefCountAccess() {}
#endif
};

}  // namespace cef_subtle

using ScopedAllowCrossThreadRefCountAccess =
    cef_subtle::ScopedAllowCrossThreadRefCountAccess;

// Concept to detect ref-counted types. This matches Chromium's definition.
template <typename T>
concept IsRefCountedType = requires(T& x) {
  // There are no additional constraints on `AddRef()` and `Release()` since
  // `scoped_refptr`, for better or worse, seamlessly interoperates with other
  // non-base types that happen to implement the same signatures (e.g. COM's
  // `IUnknown`).
  x.AddRef();
  x.Release();
};

///
/// The reference count starts from zero by default, and we intended to migrate
/// to start-from-one ref count. Put REQUIRE_ADOPTION_FOR_REFCOUNTED_TYPE() to
/// the ref counted class to opt-in.
///
/// If an object has start-from-one ref count, the first scoped_refptr need to
/// be created by base::AdoptRef() or base::MakeRefCounted(). We can use
/// base::MakeRefCounted() to create create both type of ref counted object.
///
/// The motivations to use start-from-one ref count are:
///  - Start-from-one ref count doesn't need the ref count increment for the
///    first reference.
///  - It can detect an invalid object acquisition for a being-deleted object
///    that has zero ref count. That tends to happen on custom deleter that
///    delays the deletion.
///    TODO(tzik): Implement invalid acquisition detection.
///  - Behavior parity to Blink's blink::RefCounted, whose count starts from
///    one. And start-from-one ref count is a step to merge blink::RefCounted
///    into base::RefCounted.
///
#define REQUIRE_ADOPTION_FOR_REFCOUNTED_TYPE() \
  using RefCountPreferenceTag = ::base::cef_subtle::StartRefCountFromOneTag

template <class T, typename Traits>
class RefCounted;

///
/// Default traits for RefCounted<T>.  Deletes the object when its ref count
/// reaches 0.  Overload to delete it on a different thread etc.
///
template <typename T>
struct DefaultRefCountedTraits {
  static void Destruct(const T* x) {
    RefCounted<T, DefaultRefCountedTraits>::DeleteInternal(x);
  }
};

///
/// A base class for reference counted classes.  Otherwise, known as a cheap
/// knock-off of WebKit's RefCounted<T> class.  To use this, just extend your
/// class from it like so:
///
/// <pre>
///   class MyFoo : public base::RefCounted<MyFoo> {
///    ...
///    private:
///     friend class base::RefCounted<MyFoo>;
///     ~MyFoo();
///   };
/// </pre>
///
/// Usage Notes:
/// 1. You should always make your destructor non-public, to avoid any code
///    deleting the object accidentally while there are references to it.
/// 2. You should always make the ref-counted base class a friend of your class,
///    so that it can access the destructor.
///
/// The ref count manipulation to RefCounted is NOT thread safe and has DCHECKs
/// to trap unsafe cross thread usage. A subclass instance of RefCounted can be
/// passed to another execution thread only when its ref count is 1. If the ref
/// count is more than 1, the RefCounted class verifies the ref updates are made
/// on the same execution thread as the previous ones. The subclass can also
/// manually call IsOnValidThread to trap other non-thread-safe accesses; see
/// the documentation for that method.
///
template <class T, typename Traits = DefaultRefCountedTraits<T>>
class RefCounted : public cef_subtle::RefCountedBase {
 public:
  using RefCountPreferenceTag = cef_subtle::StartRefCountFromZeroTag;

  RefCounted()
      : cef_subtle::RefCountedBase(cef_subtle::GetRefCountPreference<T>()) {}

  RefCounted(const RefCounted&) = delete;
  RefCounted& operator=(const RefCounted&) = delete;

  void AddRef() const { cef_subtle::RefCountedBase::AddRef(); }

  void Release() const {
    if (cef_subtle::RefCountedBase::Release()) {
      // Prune the code paths which the static analyzer may take to simulate
      // object destruction. Use-after-free errors aren't possible given the
      // lifetime guarantees of the refcounting system.
      ANALYZER_SKIP_THIS_PATH();

      Traits::Destruct(static_cast<const T*>(this));
    }
  }

 protected:
  ~RefCounted() = default;

 private:
  friend struct DefaultRefCountedTraits<T>;
  template <typename U>
  static void DeleteInternal(const U* x) {
    delete x;
  }
};

// Forward declaration.
template <class T, typename Traits>
class RefCountedThreadSafe;

///
/// Default traits for RefCountedThreadSafe<T>.  Deletes the object when its ref
/// count reaches 0.  Overload to delete it on a different thread etc.
///
template <typename T>
struct DefaultRefCountedThreadSafeTraits {
  static void Destruct(const T* x) {
    // Delete through RefCountedThreadSafe to make child classes only need to be
    // friend with RefCountedThreadSafe instead of this struct, which is an
    // implementation detail.
    RefCountedThreadSafe<T, DefaultRefCountedThreadSafeTraits>::DeleteInternal(
        x);
  }
};

///
/// A thread-safe variant of RefCounted<T>
///
/// <pre>
///   class MyFoo : public base::RefCountedThreadSafe<MyFoo> {
///    ...
///   };
/// </pre>
///
/// If you're using the default trait, then you should add compile time
/// asserts that no one else is deleting your object.  i.e.
/// <pre>
///    private:
///     friend class base::RefCountedThreadSafe<MyFoo>;
///     ~MyFoo();
/// </pre>
///
/// We can use REQUIRE_ADOPTION_FOR_REFCOUNTED_TYPE() with RefCountedThreadSafe
/// too. See the comment above the RefCounted definition for details.
///
template <class T, typename Traits = DefaultRefCountedThreadSafeTraits<T>>
class RefCountedThreadSafe : public cef_subtle::RefCountedThreadSafeBase {
 public:
  using RefCountPreferenceTag = cef_subtle::StartRefCountFromZeroTag;

  RefCountedThreadSafe()
      : cef_subtle::RefCountedThreadSafeBase(
            cef_subtle::GetRefCountPreference<T>()) {}

  RefCountedThreadSafe(const RefCountedThreadSafe&) = delete;
  RefCountedThreadSafe& operator=(const RefCountedThreadSafe&) = delete;

  void AddRef() const { AddRefImpl(cef_subtle::GetRefCountPreference<T>()); }

  void Release() const {
    if (cef_subtle::RefCountedThreadSafeBase::Release()) {
      ANALYZER_SKIP_THIS_PATH();
      Traits::Destruct(static_cast<const T*>(this));
    }
  }

 protected:
  ~RefCountedThreadSafe() = default;

 private:
  friend struct DefaultRefCountedThreadSafeTraits<T>;
  template <typename U>
  static void DeleteInternal(const U* x) {
    delete x;
  }

  void AddRefImpl(cef_subtle::StartRefCountFromZeroTag) const {
    cef_subtle::RefCountedThreadSafeBase::AddRef();
  }

  void AddRefImpl(cef_subtle::StartRefCountFromOneTag) const {
    cef_subtle::RefCountedThreadSafeBase::AddRefWithCheck();
  }
};

///
/// A thread-safe wrapper for some piece of data so we can place other
/// things in scoped_refptrs<>.
///
template <typename T>
class RefCountedData
    : public base::RefCountedThreadSafe<base::RefCountedData<T>> {
 public:
  RefCountedData() : data() {}
  RefCountedData(const T& in_value) : data(in_value) {}
  RefCountedData(T&& in_value) : data(std::move(in_value)) {}
  template <typename... Args>
  explicit RefCountedData(std::in_place_t, Args&&... args)
      : data(std::forward<Args>(args)...) {}

  T data;

 private:
  friend class base::RefCountedThreadSafe<base::RefCountedData<T>>;
  ~RefCountedData() = default;
};

template <typename T>
bool operator==(const RefCountedData<T>& lhs, const RefCountedData<T>& rhs) {
  return lhs.data == rhs.data;
}

}  // namespace base

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_REF_COUNTED_H_
