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

///
/// \file
/// base::BindOnce() and base::BindRepeating() are helpers for creating
/// base::OnceCallback and base::RepeatingCallback objects respectively.
///
/// For a runnable object of n-arity, the base::Bind*() family allows partial
/// application of the first m arguments. The remaining n - m arguments must be
/// passed when invoking the callback with Run().
///
/// <pre>
///   // The first argument is bound at callback creation; the remaining
///   // two must be passed when calling Run() on the callback object.
///   base::OnceCallback<long(int, long)> cb = base::BindOnce(
///       [](short x, int y, long z) { return x * y * z; }, 42);
/// </pre>
///
/// When binding to a method, the receiver object must also be specified at
/// callback creation time. When Run() is invoked, the method will be invoked on
/// the specified receiver object.
///
/// <pre>
///   class C : public base::RefCounted<C> { void F(); };
///   auto instance = base::MakeRefCounted<C>();
///   auto cb = base::BindOnce(&C::F, instance);
///   std::move(cb).Run();  // Identical to instance->F()
/// </pre>
///
/// See https://chromium.googlesource.com/chromium/src/+/lkgr/docs/callback.md
/// for the full documentation.
///

#ifndef CEF_INCLUDE_BASE_CEF_BIND_H_
#define CEF_INCLUDE_BASE_CEF_BIND_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/functional/bind.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include <functional>
#include <memory>
#include <type_traits>
#include <utility>

#include "include/base/cef_build.h"
#include "include/base/cef_compiler_specific.h"
#include "include/base/internal/cef_bind_internal.h"

// Implementation notes:
// If you're reading the implementation, before proceeding further, you should
// read the top comment of include/base/internal/cef_bind_internal.h for a
// definition of common terms and concepts.

namespace base {

///
/// Bind as OnceCallback.
///
template <typename Functor, typename... Args>
inline auto BindOnce(Functor&& functor, Args&&... args) {
  return cef_internal::BindHelper<OnceCallback>::Bind(
      std::forward<Functor>(functor), std::forward<Args>(args)...);
}

///
/// Bind as RepeatingCallback.
///
template <typename Functor, typename... Args>
inline auto BindRepeating(Functor&& functor, Args&&... args) {
  return cef_internal::BindHelper<RepeatingCallback>::Bind(
      std::forward<Functor>(functor), std::forward<Args>(args)...);
}

// Overloads to allow nicer compile errors when attempting to pass the address
// an overloaded function to `BindOnce()` or `BindRepeating()`. Otherwise, clang
// provides only the error message "no matching function [...] candidate
// template ignored: couldn't infer template argument 'Functor'", with no
// reference to the fact that `&` is being used on an overloaded function.
//
// These overloads to provide better error messages will never be selected
// unless template type deduction fails because of how overload resolution
// works; per [over.ics.rank/2.2]:
//
//   When comparing the basic forms of implicit conversion sequences (as defined
//   in [over.best.ics])
//   - a standard conversion sequence is a better conversion sequence than a
//     user-defined conversion sequence or an ellipsis conversion sequence, and
//   - a user-defined conversion sequence is a better conversion sequence than
//     an ellipsis conversion sequence.
//
// So these overloads will only be selected as a last resort iff template type
// deduction fails.
BindFailedCheckPreviousErrors BindOnce(...);
BindFailedCheckPreviousErrors BindRepeating(...);

///
/// Unretained() allows binding a non-refcounted class, and to disable
/// refcounting on arguments that are refcounted.
///
/// CEF simplified: no dangling pointer detection (UnsafeDangling,
/// UnsafeDanglingUntriaged removed).
///
/// Example of Unretained() usage:
///
/// <pre>
///   class Foo {
///    public:
///     void func() { cout << "Foo:f" << endl; }
///   };
///
///   // In some function somewhere.
///   Foo foo;
///   OnceClosure foo_callback =
///       BindOnce(&Foo::func, Unretained(&foo));
///   std::move(foo_callback).Run();  // Prints "Foo:f".
/// </pre>
///
/// Without the Unretained() wrapper on |&foo|, the above call would fail
/// to compile because Foo does not support the AddRef() and Release() methods.
///
template <typename T>
inline cef_internal::UnretainedWrapper<T> Unretained(T* o) {
  return cef_internal::UnretainedWrapper<T>(o);
}

///
/// RetainedRef() accepts a ref counted object and retains a reference to it.
/// When the callback is called, the object is passed as a raw pointer.
///
/// EXAMPLE OF RetainedRef():
///
/// <pre>
///    void foo(RefCountedBytes* bytes) {}
///
///    scoped_refptr<RefCountedBytes> bytes = ...;
///    OnceClosure callback = BindOnce(&foo, base::RetainedRef(bytes));
///    std::move(callback).Run();
/// </pre>
///
/// Without RetainedRef, the scoped_refptr would try to implicitly convert to
/// a raw pointer and fail compilation:
///
/// <pre>
///    OnceClosure callback = BindOnce(&foo, bytes); // ERROR!
/// </pre>
///
template <typename T>
inline cef_internal::RetainedRefWrapper<T> RetainedRef(T* o) {
  return cef_internal::RetainedRefWrapper<T>(o);
}
template <typename T>
inline cef_internal::RetainedRefWrapper<T> RetainedRef(scoped_refptr<T> o) {
  return cef_internal::RetainedRefWrapper<T>(std::move(o));
}

///
/// Owned() transfers ownership of an object to the callback resulting from
/// bind; the object will be deleted when the callback is deleted.
///
/// EXAMPLE OF Owned():
///
/// <pre>
///   void foo(int* arg) { cout << *arg << endl }
///
///   int* pn = new int(1);
///   RepeatingClosure foo_callback = BindRepeating(&foo, Owned(pn));
///
///   foo_callback.Run();  // Prints "1"
///   foo_callback.Run();  // Prints "1"
///   *pn = 2;
///   foo_callback.Run();  // Prints "2"
///
///   foo_callback.Reset();  // |pn| is deleted.  Also will happen when
///                          // |foo_callback| goes out of scope.
/// </pre>
///
/// Without Owned(), someone would have to know to delete |pn| when the last
/// reference to the callback is deleted.
///
template <typename T>
inline cef_internal::OwnedWrapper<T> Owned(T* o) {
  return cef_internal::OwnedWrapper<T>(o);
}

template <typename T, typename Deleter>
inline cef_internal::OwnedWrapper<T, Deleter> Owned(
    std::unique_ptr<T, Deleter>&& ptr) {
  return cef_internal::OwnedWrapper<T, Deleter>(std::move(ptr));
}

///
/// OwnedRef() stores an object in the callback resulting from
/// bind and passes a reference to the object to the bound function.
///
/// EXAMPLE OF OwnedRef():
///
/// <pre>
///   void foo(int& arg) { cout << ++arg << endl }
///
///   int counter = 0;
///   RepeatingClosure foo_callback = BindRepeating(&foo, OwnedRef(counter));
///
///   foo_callback.Run();  // Prints "1"
///   foo_callback.Run();  // Prints "2"
///   foo_callback.Run();  // Prints "3"
///
///   cout << counter;     // Prints "0", OwnedRef creates a copy of counter.
/// </pre>
///
///  Supports OnceCallbacks as well, useful to pass placeholder arguments:
///
/// <pre>
///   void bar(int& ignore, const std::string& s) { cout << s << endl }
///
///   OnceClosure bar_callback = BindOnce(&bar, OwnedRef(0), "Hello");
///
///   std::move(bar_callback).Run(); // Prints "Hello"
/// </pre>
///
/// Without OwnedRef() it would not be possible to pass a mutable reference to
/// an object owned by the callback.
///
template <typename T>
cef_internal::OwnedRefWrapper<std::decay_t<T>> OwnedRef(T&& t) {
  return cef_internal::OwnedRefWrapper<std::decay_t<T>>(std::forward<T>(t));
}

///
/// Passed() is for transferring movable-but-not-copyable types (eg. unique_ptr)
/// through a RepeatingCallback. Logically, this signifies a destructive
/// transfer of the state of the argument into the target function. Invoking
/// RepeatingCallback::Run() twice on a callback that was created with a
/// Passed() argument will CHECK() because the first invocation would have
/// already transferred ownership to the target function.
///
/// Note that Passed() is not necessary with BindOnce(), as std::move() does the
/// same thing. Avoid Passed() in favor of std::move() with BindOnce().
///
/// EXAMPLE OF Passed():
///
/// <pre>
///   void TakesOwnership(std::unique_ptr<Foo> arg) { }
///   std::unique_ptr<Foo> CreateFoo() { return std::make_unique<Foo>();
///   }
///
///   auto f = std::make_unique<Foo>();
///
///   // |cb| is given ownership of Foo(). |f| is now NULL.
///   // You can use std::move(f) in place of &f, but it's more verbose.
///   RepeatingClosure cb = BindRepeating(&TakesOwnership, Passed(&f));
///
///   // Run was never called so |cb| still owns Foo() and deletes
///   // it on Reset().
///   cb.Reset();
///
///   // |cb| is given a new Foo created by CreateFoo().
///   cb = BindRepeating(&TakesOwnership, Passed(CreateFoo()));
///
///   // |arg| in TakesOwnership() is given ownership of Foo(). |cb|
///   // no longer owns Foo() and, if reset, would not delete Foo().
///   cb.Run();  // Foo() is now transferred to |arg| and deleted.
///   cb.Run();  // This CHECK()s since Foo() already been used once.
/// </pre>
///
/// We offer 2 syntaxes for calling Passed(). The first takes an rvalue and is
/// best suited for use with the return value of a function or other temporary
/// rvalues. The second takes a pointer to the scoper and is just syntactic
/// sugar to avoid having to write Passed(std::move(scoper)).
///
/// Both versions of Passed() prevent T from being an lvalue reference. The
/// first via use of enable_if, and the second takes a T* which will not bind to
/// T&.
///
/// DEPRECATED - Do not use in new code. See https://crbug.com/1326449
///
template <typename T>
  requires(!std::is_lvalue_reference_v<T>)
inline cef_internal::PassedWrapper<T> Passed(T&& scoper) {
  return cef_internal::PassedWrapper<T>(std::move(scoper));
}
template <typename T>
inline cef_internal::PassedWrapper<T> Passed(T* scoper) {
  return cef_internal::PassedWrapper<T>(std::move(*scoper));
}

///
/// IgnoreResult() is used to adapt a function or callback with a return type to
/// one with a void return. This is most useful if you have a function with,
/// say, a pesky ignorable bool return that you want to use with PostTask or
/// something else that expect a callback with a void return.
///
/// EXAMPLE OF IgnoreResult():
///
/// <pre>
///   int DoSomething(int arg) { cout << arg << endl; }
///
///   // Assign to a callback with a void return type.
///   OnceCallback<void(int)> cb = BindOnce(IgnoreResult(&DoSomething));
///   std::move(cb).Run(1);  // Prints "1".
///
///   // Prints "2" on |ml|.
///   ml->PostTask(FROM_HERE, BindOnce(IgnoreResult(&DoSomething), 2);
/// </pre>
///
template <typename T>
inline cef_internal::IgnoreResultHelper<T> IgnoreResult(T data) {
  return cef_internal::IgnoreResultHelper<T>(std::move(data));
}

}  // namespace base

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_BIND_H_
