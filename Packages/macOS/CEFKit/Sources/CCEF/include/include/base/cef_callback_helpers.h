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

// This defines helpful methods for dealing with Callbacks.  Because Callbacks
// are implemented using templates, with a class per callback signature, adding
// methods to Callback<> itself is unattractive (lots of extra code gets
// generated).  Instead, consider adding methods here.

#ifndef CEF_INCLUDE_BASE_CEF_CALLBACK_HELPERS_H_
#define CEF_INCLUDE_BASE_CEF_CALLBACK_HELPERS_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/functional/callback_helpers.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include <atomic>
#include <memory>
#include <ostream>
#include <type_traits>
#include <utility>
#include <vector>

#include "include/base/cef_bind.h"
#include "include/base/cef_callback.h"
#include "include/base/cef_logging.h"
#include "include/base/internal/cef_callback_tags.h"

namespace base {

namespace cef_internal {

template <typename T>
struct IsBaseCallbackImpl : std::false_type {};

template <typename R, typename... Args>
struct IsBaseCallbackImpl<OnceCallback<R(Args...)>> : std::true_type {};

template <typename R, typename... Args>
struct IsBaseCallbackImpl<RepeatingCallback<R(Args...)>> : std::true_type {};

}  // namespace cef_internal

///
/// IsBaseCallback<T> is satisfied if and only if T is an instantiation of
/// base::OnceCallback<Signature> or base::RepeatingCallback<Signature>.
///
template <typename T>
concept IsBaseCallback =
    cef_internal::IsBaseCallbackImpl<std::decay_t<T>>::value;

namespace cef_internal {

template <typename... Args>
class OnceCallbackHolder final {
 public:
  OnceCallbackHolder(OnceCallback<void(Args...)> callback,
                     bool ignore_extra_runs)
      : callback_(std::move(callback)), ignore_extra_runs_(ignore_extra_runs) {
    DCHECK(callback_);
  }
  OnceCallbackHolder(const OnceCallbackHolder&) = delete;
  OnceCallbackHolder& operator=(const OnceCallbackHolder&) = delete;

  void Run(Args... args) {
    if (has_run_.exchange(true, std::memory_order_relaxed)) {
      CHECK(ignore_extra_runs_) << "Both OnceCallbacks returned by "
                                   "base::SplitOnceCallback() were run. "
                                   "At most one of the pair should be run.";
      return;
    }
    DCHECK(callback_);
    std::move(callback_).Run(std::forward<Args>(args)...);
  }

 private:
  std::atomic<bool> has_run_{false};
  base::OnceCallback<void(Args...)> callback_;
  const bool ignore_extra_runs_;
};

template <typename... Args>
void ForwardRepeatingCallbacksImpl(
    std::vector<RepeatingCallback<void(Args...)>> cbs,
    Args... args) {
  for (auto& cb : cbs) {
    if (cb) {
      cb.Run(std::forward<Args>(args)...);
    }
  }
}

}  // namespace cef_internal

///
/// Wraps the given RepeatingCallbacks and return one RepeatingCallbacks with an
/// identical signature. On invocation of this callback, all the given
/// RepeatingCallbacks will be called with the same arguments. Unbound arguments
/// must be copyable.
///
template <typename... Args>
RepeatingCallback<void(Args...)> ForwardRepeatingCallbacks(
    std::initializer_list<RepeatingCallback<void(Args...)>>&& cbs) {
  std::vector<RepeatingCallback<void(Args...)>> v(
      std::forward<std::initializer_list<RepeatingCallback<void(Args...)>>>(
          cbs));
  return BindRepeating(&cef_internal::ForwardRepeatingCallbacksImpl<Args...>,
                       std::move(v));
}

///
/// Wraps the given OnceCallback and returns two OnceCallbacks with an identical
/// signature. On first invokation of either returned callbacks, the original
/// callback is invoked. Invoking the remaining callback results in a crash.
///
template <typename... Args>
std::pair<OnceCallback<void(Args...)>, OnceCallback<void(Args...)>>
SplitOnceCallback(OnceCallback<void(Args...)> callback) {
  if (!callback) {
    // Empty input begets two empty outputs.
    return std::make_pair(OnceCallback<void(Args...)>(),
                          OnceCallback<void(Args...)>());
  }
  using Helper = cef_internal::OnceCallbackHolder<Args...>;
  auto wrapped_once = base::BindRepeating(
      &Helper::Run, std::make_unique<Helper>(std::move(callback),
                                             /*ignore_extra_runs=*/false));
  return std::make_pair(wrapped_once, wrapped_once);
}

///
/// Adapts `callback` for use in a context which is expecting a callback with
/// additional parameters. Returns a null callback if `callback` is null.
///
/// Usage:
///
/// <pre>
///   bool LogError(char* error_message) {
///     if (error_message) {
///       cout << "Log: " << error_message << endl;
///       return false;
///     }
///     return true;
///   }
///   base::RepeatingCallback<bool(int, char*)> cb =
///      base::IgnoreArgs<int>(base::BindRepeating(&LogError));
///   CHECK_EQ(true, cb.Run(42, nullptr));
/// </pre>
///
/// Note in the example above that the type(s) passed to `IgnoreArgs`
/// represent the additional prepended parameters (those which will be
/// "ignored").
///
template <typename... Preargs, typename... Args, typename R>
RepeatingCallback<R(Preargs..., Args...)> IgnoreArgs(
    RepeatingCallback<R(Args...)> callback) {
  return callback ? ::base::BindRepeating(
                        [](RepeatingCallback<R(Args...)> callback, Preargs...,
                           Args... args) {
                          return std::move(callback).Run(
                              std::forward<Args>(args)...);
                        },
                        std::move(callback))
                  : RepeatingCallback<R(Preargs..., Args...)>();
}

/// As above, but for OnceCallback.
template <typename... Preargs, typename... Args, typename R>
OnceCallback<R(Preargs..., Args...)> IgnoreArgs(
    OnceCallback<R(Args...)> callback) {
  return callback ? ::base::BindOnce(
                        [](OnceCallback<R(Args...)> callback, Preargs...,
                           Args... args) {
                          return std::move(callback).Run(
                              std::forward<Args>(args)...);
                        },
                        std::move(callback))
                  : OnceCallback<R(Preargs..., Args...)>();
}

///
/// ScopedClosureRunner is akin to std::unique_ptr<> for Closures. It ensures
/// that the Closure is executed no matter how the current scope exits.
/// If you are looking for "ScopedCallback", "CallbackRunner", or
/// "CallbackScoper" this is the class you want.
///
class ScopedClosureRunner {
 public:
  ScopedClosureRunner();
  [[nodiscard]] explicit ScopedClosureRunner(OnceClosure closure);
  ScopedClosureRunner(ScopedClosureRunner&& other);
  // Runs the current closure if it's set, then replaces it with the closure
  // from |other|. This is akin to how unique_ptr frees the contained pointer in
  // its move assignment operator. If you need to explicitly avoid running any
  // current closure, use ReplaceClosure().
  ScopedClosureRunner& operator=(ScopedClosureRunner&& other);
  ~ScopedClosureRunner();

  explicit operator bool() const { return !!closure_; }

  // Calls the current closure and resets it, so it wont be called again.
  void RunAndReset();

  // Replaces closure with the new one releasing the old one without calling it.
  void ReplaceClosure(OnceClosure closure);

  // Releases the Closure without calling.
  [[nodiscard]] OnceClosure Release();

 private:
  OnceClosure closure_;
};

///
/// Returns a placeholder type that will implicitly convert into a null
/// callback, similar to how std::nullopt / std::nullptr work in conjunction
/// with std::optional and various smart pointer types.
///
constexpr auto NullCallback() {
  return cef_internal::NullCallbackTag();
}

///
/// Returns a placeholder type that will implicitly convert into a callback that
/// does nothing, similar to how std::nullopt / std::nullptr work in conjunction
/// with std::optional and various smart pointer types.
///
constexpr auto DoNothing() {
  return cef_internal::DoNothingCallbackTag();
}

///
/// Similar to the above, but with a type hint. Useful for disambiguating
/// among multiple function overloads that take callbacks with different
/// signatures:
///
/// <pre>
/// void F(base::OnceCallback<void()> callback);     // 1
/// void F(base::OnceCallback<void(int)> callback);  // 2
///
/// F(base::NullCallbackAs<void()>());               // calls 1
/// F(base::DoNothingAs<void(int)>());               // calls 2
/// </pre>
///
template <typename Signature>
constexpr auto NullCallbackAs() {
  return cef_internal::NullCallbackTag::WithSignature<Signature>();
}

template <typename Signature>
constexpr auto DoNothingAs() {
  return cef_internal::DoNothingCallbackTag::WithSignature<Signature>();
}

///
/// Similar to DoNothing above, but with bound arguments. This helper is useful
/// for keeping objects alive until the callback runs.
/// Example:
///
/// <pre>
/// void F(base::OnceCallback<void(int)> result_callback);
///
/// std::unique_ptr<MyClass> ptr;
/// F(base::DoNothingWithBoundArgs(std::move(ptr)));
/// </pre>
///
template <typename... Args>
constexpr auto DoNothingWithBoundArgs(Args&&... args) {
  return cef_internal::DoNothingCallbackTag::WithBoundArguments(
      std::forward<Args>(args)...);
}

///
/// Creates a callback that returns `value` when invoked. This helper is useful
/// for implementing factories that return a constant value.
/// Example:
///
/// <pre>
/// void F(base::OnceCallback<Widget()> factory);
///
/// Widget widget = ...;
/// F(base::ReturnValueOnce(std::move(widget)));
/// </pre>
///
template <typename T>
constexpr OnceCallback<T(void)> ReturnValueOnce(T value) {
  static_assert(!std::is_reference_v<T>);
  return base::BindOnce([](T value) { return value; }, std::move(value));
}

///
/// Useful for creating a Closure that will delete a pointer when invoked. Only
/// use this when necessary. In most cases MessageLoop::DeleteSoon() is a better
/// fit.
///
template <typename T>
void DeletePointer(T* obj) {
  delete obj;
}

#if __OBJC__

///
/// Creates an Objective-C block with the same signature as the corresponding
/// callback. Can be used to implement a callback based API internally based
/// on a block based Objective-C API.
///
/// Overloaded to work with both repeating and one shot callbacks. Calling the
/// block wrapping a base::OnceCallback<...> multiple times will crash (there
/// is no way to mark the block as callable only once). Only use that when you
/// know that Objective-C API will only invoke the block once.
///
template <typename R, typename... Args>
auto CallbackToBlock(base::OnceCallback<R(Args...)> callback) {
  __block base::OnceCallback<R(Args...)> block_callback = std::move(callback);
  return ^(Args... args) {
    return std::move(block_callback).Run(std::forward<Args>(args)...);
  };
}

template <typename R, typename... Args>
auto CallbackToBlock(base::RepeatingCallback<R(Args...)> callback) {
  return ^(Args... args) {
    return callback.Run(std::forward<Args>(args)...);
  };
}

#endif  // __OBJC__

}  // namespace base

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_CALLBACK_HELPERS_H_
