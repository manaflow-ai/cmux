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

///
/// \file
/// Weak pointers are pointers to an object that do not affect its lifetime,
/// and which may be invalidated (i.e. reset to nullptr) by the object, or its
/// owner, at any time, most commonly when the object is about to be deleted.
///
/// Weak pointers are useful when an object needs to be accessed safely by one
/// or more objects other than its owner, and those callers can cope with the
/// object vanishing and e.g. tasks posted to it being silently dropped.
/// Reference-counting such an object would complicate the ownership graph and
/// make it harder to reason about the object's lifetime.
///
/// EXAMPLE:
///
/// <pre>
///  class Controller {
///   public:
///    void SpawnWorker() { Worker::StartNew(weak_factory_.GetWeakPtr()); }
///    void WorkComplete(const Result& result) { ... }
///   private:
///    // Member variables should appear before the WeakPtrFactory, to ensure
///    // that any WeakPtrs to Controller are invalidated before its members
///    // variable's destructors are executed, rendering them invalid.
///    WeakPtrFactory<Controller> weak_factory_{this};
///  };
///
///  class Worker {
///   public:
///    static void StartNew(WeakPtr<Controller> controller) {
///      // Move WeakPtr when possible to avoid atomic refcounting churn on its
///      // internal state.
///      Worker* worker = new Worker(std::move(controller));
///      // Kick off asynchronous processing...
///    }
///   private:
///    Worker(WeakPtr<Controller> controller)
///        : controller_(std::move(controller)) {}
///    void DidCompleteAsynchronousProcessing(const Result& result) {
///      if (controller_)
///        controller_->WorkComplete(result);
///    }
///    WeakPtr<Controller> controller_;
///  };
/// </pre>
///
/// With this implementation a caller may use SpawnWorker() to dispatch multiple
/// Workers and subsequently delete the Controller, without waiting for all
/// Workers to have completed.
///
/// <b>IMPORTANT: Thread-safety</b>
///
/// Weak pointers may be passed safely between threads, but must always be
/// dereferenced and invalidated on the same thread otherwise checking the
/// pointer would be racey.
///
/// To ensure correct use, the first time a WeakPtr issued by a WeakPtrFactory
/// is dereferenced, the factory and its WeakPtrs become bound to the calling
/// thread, and cannot be dereferenced or invalidated on any other task runner.
/// Bound WeakPtrs can still be handed off to other task runners, e.g. to use
/// to post tasks back to object on the bound thread.
///
/// If all WeakPtr objects are destroyed or invalidated then the factory is
/// unbound from the thread. The WeakPtrFactory may then be destroyed, or new
/// WeakPtr objects may be used, from a different thread.
///
/// Thus, at least one WeakPtr object must exist and have been dereferenced on
/// the correct thread to enforce that other WeakPtr objects will enforce they
/// are used on the desired thread.

#ifndef CEF_INCLUDE_BASE_CEF_WEAK_PTR_H_
#define CEF_INCLUDE_BASE_CEF_WEAK_PTR_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/memory/weak_ptr.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include <cstddef>
#include <concepts>
#include <type_traits>
#include <utility>

#include "include/base/cef_atomic_flag.h"
#include "include/base/cef_logging.h"
#include "include/base/cef_ref_counted.h"
#include "include/base/cef_thread_checker.h"

namespace base {

template <typename T>
class WeakPtr;

namespace cef_internal {
// These classes are part of the WeakPtr implementation.
// DO NOT USE THESE CLASSES DIRECTLY YOURSELF.

class WeakReference {
 public:
  // Although Flag is bound to a specific thread, it may be
  // deleted from another via base::WeakPtr::~WeakPtr().
  class Flag : public RefCountedThreadSafe<Flag> {
   public:
    Flag();

    void Invalidate();
    bool IsValid() const;

    bool MaybeValid() const;

#if DCHECK_IS_ON()
    void DetachFromThread();
    void BindToCurrentThread();
#endif

   private:
    friend class base::RefCountedThreadSafe<Flag>;

    ~Flag();

    base::ThreadChecker thread_checker_;
    AtomicFlag invalidated_;
  };

  WeakReference();
  explicit WeakReference(const scoped_refptr<Flag>& flag);
  ~WeakReference();

  WeakReference(const WeakReference& other);
  WeakReference& operator=(const WeakReference& other);

  WeakReference(WeakReference&& other) noexcept;
  WeakReference& operator=(WeakReference&& other) noexcept;

  void Reset();
  // Returns whether the WeakReference is valid, meaning the WeakPtrFactory has
  // not invalidated the pointer. Unlike, MaybeValid(), this may only be
  // called from the same thread as where the WeakPtr was created.
  bool IsValid() const;
  // Returns false if the WeakReference is confirmed to be invalid. This call is
  // safe to make from any thread, e.g. to optimize away unnecessary work, but
  // IsValid() must always be called, on the correct thread, before
  // actually using the pointer.
  //
  // Warning: as with any object, this call is only thread-safe if the WeakPtr
  // instance isn't being re-assigned or reset() racily with this call.
  bool MaybeValid() const;

 private:
  scoped_refptr<const Flag> flag_;
};

class WeakReferenceOwner {
 public:
  WeakReferenceOwner();
  ~WeakReferenceOwner();

  WeakReference GetRef() const;

  bool HasRefs() const { return !flag_->HasOneRef(); }

  void Invalidate();
  void InvalidateAndDoom();
  void BindToCurrentThread();

 private:
  scoped_refptr<WeakReference::Flag> flag_;
};

class WeakPtrFactoryBase {
 protected:
  WeakPtrFactoryBase(uintptr_t ptr);
  ~WeakPtrFactoryBase();
  cef_internal::WeakReferenceOwner weak_reference_owner_;
  uintptr_t ptr_;
};

}  // namespace cef_internal

template <typename T>
class WeakPtrFactory;

///
/// The WeakPtr class holds a weak reference to |T*|.
///
/// This class is designed to be used like a normal pointer.  You should always
/// null-test an object of this class before using it or invoking a method that
/// may result in the underlying object being destroyed.
///
/// EXAMPLE:
///
/// <pre>
///   class Foo { ... };
///   WeakPtr<Foo> foo;
///   if (foo)
///     foo->method();
/// </pre>
///
/// WeakPtr intentionally doesn't implement operator== or operator<=>, because
/// comparisons of weak references are inherently unstable. If the comparison
/// takes validity into account, the result can change at any time as pointers
/// are invalidated. If it depends only on the underlying pointer value, even
/// after the pointer is invalidated, unrelated WeakPtrs can unexpectedly
/// compare equal if the address is reused.
///
template <typename T>
class WeakPtr {
 public:
  WeakPtr() = default;
  // NOLINTNEXTLINE(google-explicit-constructor)
  WeakPtr(std::nullptr_t) {}

  ///
  /// Allow conversion from U to T provided U "is a" T. Note that this
  /// is separate from the (implicit) copy and move constructors.
  ///
  template <typename U>
    requires(std::convertible_to<U*, T*>)
  // NOLINTNEXTLINE(google-explicit-constructor)
  WeakPtr(const WeakPtr<U>& other) : ref_(other.ref_), ptr_(other.ptr_) {}
  template <typename U>
    requires(std::convertible_to<U*, T*>)
  // NOLINTNEXTLINE(google-explicit-constructor)
  WeakPtr& operator=(const WeakPtr<U>& other) {
    ref_ = other.ref_;
    ptr_ = other.ptr_;
    return *this;
  }

  template <typename U>
    requires(std::convertible_to<U*, T*>)
  // NOLINTNEXTLINE(google-explicit-constructor)
  WeakPtr(WeakPtr<U>&& other)
      : ref_(std::move(other.ref_)), ptr_(std::move(other.ptr_)) {}
  template <typename U>
    requires(std::convertible_to<U*, T*>)
  // NOLINTNEXTLINE(google-explicit-constructor)
  WeakPtr& operator=(WeakPtr<U>&& other) {
    ref_ = std::move(other.ref_);
    ptr_ = std::move(other.ptr_);
    return *this;
  }

  T* get() const { return ref_.IsValid() ? ptr_ : nullptr; }

  ///
  /// Provide access to the underlying T as a reference. Will CHECK() if the T
  /// pointee is no longer alive.
  ///
  T& operator*() const {
    CHECK(ref_.IsValid());
    return *ptr_;
  }

  ///
  /// Used to call methods on the underlying T. Will CHECK() if the T pointee
  /// is no longer alive.
  ///
  T* operator->() const {
    CHECK(ref_.IsValid());
    return ptr_;
  }

  ///
  /// Allow conditionals to test validity, e.g. if (weak_ptr) {...};
  ///
  explicit operator bool() const { return get() != nullptr; }

  ///
  /// Resets the WeakPtr to hold nothing.
  ///
  /// The `get()` method will return `nullptr` thereafter, and `MaybeValid()`
  /// will be `false`.
  ///
  void reset() {
    ref_.Reset();
    ptr_ = nullptr;
  }

  ///
  /// Do not use this method. Almost all callers should instead use operator
  /// bool().
  ///
  /// There are a few rare cases where the caller intentionally needs to check
  /// validity of a base::WeakPtr on a thread different from the bound thread
  /// as an unavoidable performance optimization.
  ///
  /// Returns false if the WeakPtr is confirmed to be invalid. This call is
  /// safe to make from any thread, e.g. to optimize away unnecessary work, but
  /// IsValid() must always be called, on the correct thread, before actually
  /// using the pointer.
  ///
  /// Warning: as with any object, this call is only thread-safe if the WeakPtr
  /// instance isn't being re-assigned or reset() racily with this call.
  ///
  bool MaybeValid() const { return ref_.MaybeValid(); }

  ///
  /// Returns whether the object |this| points to has been invalidated. This
  /// can be used to distinguish a WeakPtr to a destroyed object from one that
  /// has been explicitly set to null.
  ///
  bool WasInvalidated() const { return ptr_ && !ref_.IsValid(); }

 private:
  template <typename U>
  friend class WeakPtr;
  friend class WeakPtrFactory<T>;
  friend class WeakPtrFactory<std::remove_const_t<T>>;

  WeakPtr(cef_internal::WeakReference&& ref, T* ptr)
      : ref_(std::move(ref)), ptr_(ptr) {
    DCHECK(ptr);
  }

  cef_internal::WeakReference CloneWeakReference() const { return ref_; }

  cef_internal::WeakReference ref_;

  // This pointer is only valid when ref_.is_valid() is true.  Otherwise, its
  // value is undefined (as opposed to nullptr). The pointer is allowed to
  // dangle as we verify its liveness through `ref_` before allowing access to
  // the pointee.
  T* ptr_ = nullptr;
};

///
/// Allow callers to compare WeakPtrs against nullptr to test validity.
///
template <class T>
bool operator!=(const WeakPtr<T>& weak_ptr, std::nullptr_t) {
  return !(weak_ptr == nullptr);
}
template <class T>
bool operator!=(std::nullptr_t, const WeakPtr<T>& weak_ptr) {
  return weak_ptr != nullptr;
}
template <class T>
bool operator==(const WeakPtr<T>& weak_ptr, std::nullptr_t) {
  return weak_ptr.get() == nullptr;
}
template <class T>
bool operator==(std::nullptr_t, const WeakPtr<T>& weak_ptr) {
  return weak_ptr == nullptr;
}

///
/// A class may be composed of a WeakPtrFactory and thereby control how it
/// exposes weak pointers to itself.  This is helpful if you only need weak
/// pointers within the implementation of a class.  This class is also useful
/// when working with primitive types.  For example, you could have a
/// WeakPtrFactory<bool> that is used to pass around a weak reference to a
/// bool.
///
template <class T>
class WeakPtrFactory : public cef_internal::WeakPtrFactoryBase {
 public:
  WeakPtrFactory() = delete;

  explicit WeakPtrFactory(T* ptr)
      : WeakPtrFactoryBase(reinterpret_cast<uintptr_t>(ptr)) {}

  WeakPtrFactory(const WeakPtrFactory&) = delete;
  WeakPtrFactory& operator=(const WeakPtrFactory&) = delete;

  ~WeakPtrFactory() = default;

  WeakPtr<const T> GetWeakPtr() const {
    return WeakPtr<const T>(weak_reference_owner_.GetRef(),
                            reinterpret_cast<const T*>(ptr_));
  }

  WeakPtr<T> GetWeakPtr()
    requires(!std::is_const_v<T>)
  {
    return WeakPtr<T>(weak_reference_owner_.GetRef(),
                      reinterpret_cast<T*>(ptr_));
  }

  WeakPtr<T> GetMutableWeakPtr() const
    requires(!std::is_const_v<T>)
  {
    return WeakPtr<T>(weak_reference_owner_.GetRef(),
                      reinterpret_cast<T*>(ptr_));
  }

  ///
  /// Invalidates all existing weak pointers.
  ///
  void InvalidateWeakPtrs() {
    DCHECK(ptr_);
    weak_reference_owner_.Invalidate();
  }

  ///
  /// Invalidates all existing weak pointers, and makes the factory unusable
  /// (cannot call GetWeakPtr after this). This is more efficient than
  /// InvalidateWeakPtrs().
  ///
  void InvalidateWeakPtrsAndDoom() {
    DCHECK(ptr_);
    weak_reference_owner_.InvalidateAndDoom();
    ptr_ = 0;
  }

  ///
  /// Call this method to determine if any weak pointers exist.
  ///
  bool HasWeakPtrs() const { return ptr_ && weak_reference_owner_.HasRefs(); }

  ///
  /// Rebind the factory to the current thread. This allows creating an object
  /// and associated weak pointers on a different thread from the one they are
  /// used on.
  ///
  void BindToCurrentThread() {
    weak_reference_owner_.BindToCurrentThread();
  }
};

}  // namespace base

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_WEAK_PTR_H_
