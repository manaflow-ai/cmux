// Copyright (c) 2021 Marshall A. Greenblatt. Portions copyright (c) 2012
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

#ifndef CEF_INCLUDE_BASE_CEF_COMPILER_SPECIFIC_H_
#define CEF_INCLUDE_BASE_CEF_COMPILER_SPECIFIC_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/compiler_specific.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include "include/base/cef_build.h"

// A wrapper around `__has_attribute()`, which is similar to the C++20-standard
// `__has_cpp_attribute()`, but tests for support for `__attribute__(())`s.
// Compilers that do not support this (e.g. MSVC) are also assumed not to
// support `__attribute__`, so this is simply mapped to `0` there.
//
// See also:
//   https://clang.llvm.org/docs/LanguageExtensions.html#has-attribute
#if defined(__has_attribute)
#define HAS_ATTRIBUTE(x) __has_attribute(x)
#else
#define HAS_ATTRIBUTE(x) 0
#endif

// A wrapper around `__has_builtin`, similar to `HAS_ATTRIBUTE()`.
//
// See also:
//   https://clang.llvm.org/docs/LanguageExtensions.html#has-builtin
#if defined(__has_builtin)
#define HAS_BUILTIN(x) __has_builtin(x)
#else
#define HAS_BUILTIN(x) 0
#endif

// A wrapper around `__has_feature`, similar to `HAS_ATTRIBUTE()`.
//
// See also:
//   https://clang.llvm.org/docs/LanguageExtensions.html#has-feature-and-has-extension
#if defined(__has_feature)
#define HAS_FEATURE(FEATURE) __has_feature(FEATURE)
#else
#define HAS_FEATURE(FEATURE) 0
#endif

// Annotates a function indicating it should not be inlined.
//
// See also:
//   https://clang.llvm.org/docs/AttributeReference.html#noinline
//
// Usage:
// ```
//   NOINLINE void Func() {
//     // This body will not be inlined into callers.
//   }
// ```
#if __has_cpp_attribute(clang::noinline)
#define NOINLINE [[clang::noinline]]
#elif __has_cpp_attribute(gnu::noinline)
#define NOINLINE [[gnu::noinline]]
#elif __has_cpp_attribute(msvc::noinline)
#define NOINLINE [[msvc::noinline]]
#else
#define NOINLINE
#endif

// Annotates a function indicating it should always be inlined.
//
// See also:
//   https://clang.llvm.org/docs/AttributeReference.html#always-inline-force-inline
//
// Usage:
// ```
//   ALWAYS_INLINE void Func() {
//     // This body will be inlined into callers whenever possible.
//   }
// ```
//
// Since `ALWAYS_INLINE` is performance-oriented but can hamper debugging,
// ignore it in debug mode.
#if defined(NDEBUG)
#if __has_cpp_attribute(clang::always_inline)
#define ALWAYS_INLINE [[clang::always_inline]] inline
#elif __has_cpp_attribute(gnu::always_inline)
#define ALWAYS_INLINE [[gnu::always_inline]] inline
#elif defined(COMPILER_MSVC)
#define ALWAYS_INLINE __forceinline
#endif
#endif
#if !defined(ALWAYS_INLINE)
#define ALWAYS_INLINE inline
#endif

// Annotates a function indicating it should never be tail called. Useful to
// make sure callers of the annotated function are never omitted from call
// stacks. Often useful with `NOINLINE` to make sure the function itself is also
// not omitted from call stacks. Note: this does not prevent code folding of
// multiple identical callers into a single signature; to do that, see
// `NO_CODE_FOLDING()` in base/debug/alias.h.
//
// See also:
//   https://clang.llvm.org/docs/AttributeReference.html#not-tail-called
//
// Usage:
// ```
//   // Calls to this function will not be tail calls.
//   NOT_TAIL_CALLED void Func();
// ```
#if __has_cpp_attribute(clang::not_tail_called)
#define NOT_TAIL_CALLED [[clang::not_tail_called]]
#else
#define NOT_TAIL_CALLED
#endif

// Annotates a data member indicating it need not have an address distinct from
// all other non-static data members of the class, and its tail padding may be
// used for other objects' storage. This can have subtle and dangerous effects,
// including on containing objects; use with caution.
//
// See also:
//   https://en.cppreference.com/w/cpp/language/attributes/no_unique_address
//   https://wg21.link/dcl.attr.nouniqueaddr
// Usage:
// ```
//   // In the following struct, `t` might not have a unique address from `i`,
//   // and `t`'s tail padding (if any) may be reused by subsequent objects.
//   struct S {
//     int i;
//     NO_UNIQUE_ADDRESS T t;
//   };
// ```
//
// Unfortunately MSVC ignores [[no_unique_address]] (see
// https://devblogs.microsoft.com/cppblog/msvc-cpp20-and-the-std-cpp20-switch/#msvc-extensions-and-abi),
// and clang-cl matches it for ABI compatibility reasons. We need to prefer
// [[msvc::no_unique_address]] when available if we actually want any effect.
#if __has_cpp_attribute(msvc::no_unique_address)
#define NO_UNIQUE_ADDRESS [[msvc::no_unique_address]]
#elif __has_cpp_attribute(no_unique_address)
#define NO_UNIQUE_ADDRESS [[no_unique_address]]
#else
#define NO_UNIQUE_ADDRESS
#endif

// Annotates a function indicating it takes a `printf()`-style format string.
// The compiler will check that the provided arguments match the type specifiers
// in the format string. Useful to detect mismatched format strings/args.
//
// `format_param` is the one-based index of the format string parameter;
// `dots_param` is the one-based index of the "..." parameter.
// For `v*printf()` functions (which take a `va_list`), `dots_param` should be
// 0. For member functions, the implicit `this` parameter is at index 1.
//
// See also:
//   https://clang.llvm.org/docs/AttributeReference.html#format
//   https://gcc.gnu.org/onlinedocs/gcc/Common-Function-Attributes.html#index-format-function-attribute
//
// Usage:
// ```
//   PRINTF_FORMAT(1, 2)
//   void Print(const char* format, ...);
//   void Func() {
//     // The following call will not compile; diagnosed as format and argument
//     // types mismatching.
//     Print("%s", 1);
//   }
// ```
#if __has_cpp_attribute(gnu::format)
#define PRINTF_FORMAT(format_param, dots_param) \
  [[gnu::format(printf, format_param, dots_param)]]
#else
#define PRINTF_FORMAT(format_param, dots_param)
#endif

// Annotates a function disabling the named sanitizer within its body.
//
// See also:
//   https://clang.llvm.org/docs/AttributeReference.html#no-sanitize
//   https://clang.llvm.org/docs/UsersManual.html#controlling-code-generation
//
// Usage:
// ```
//   NO_SANITIZE("cfi-icall") void Func() {
//     // CFI indirect call checks will not be performed in this body.
//   }
// ```
#if __has_cpp_attribute(clang::no_sanitize)
#define NO_SANITIZE(sanitizer) [[clang::no_sanitize(sanitizer)]]
#else
#define NO_SANITIZE(sanitizer)
#endif

// Annotates a pointer and size directing MSAN to treat that memory region as
// fully initialized. Useful for e.g. code that deliberately reads uninitialized
// data, such as a GC scavenging root set pointers from the stack.
//
// See also:
//   https://github.com/google/sanitizers/wiki/MemorySanitizer
//
// Usage:
// ```
//   T* ptr = ...;
//   // After the next statement, MSAN will assume `ptr` points to an
//   // initialized `T`.
//   MSAN_UNPOISON(ptr, sizeof(T));
// ```
#if defined(MEMORY_SANITIZER)
#include <sanitizer/msan_interface.h>
#define MSAN_UNPOISON(p, size) __msan_unpoison(p, size)
#else
#define MSAN_UNPOISON(p, size)
#endif

// Annotates a pointer and size directing MSAN to check whether that memory
// region is initialized, as if it was being read from. If any bits are
// uninitialized, crashes with an MSAN report. Useful for e.g. sanitizing data
// MSAN won't be able to track, such as data that is about to be passed to
// another process via shared memory.
//
// See also:
//   https://www.chromium.org/developers/testing/memorysanitizer/#debugging-msan-reports
//
// Usage:
// ```
//   T* ptr = ...;
//   // The following line will crash at runtime in MSAN builds if `ptr` does
//   // not point to an initialized `T`.
//   MSAN_CHECK_MEM_IS_INITIALIZED(ptr, sizeof(T));
// ```
#if defined(MEMORY_SANITIZER)
#define MSAN_CHECK_MEM_IS_INITIALIZED(p, size) \
  __msan_check_mem_is_initialized(p, size)
#else
#define MSAN_CHECK_MEM_IS_INITIALIZED(p, size)
#endif

// Annotates a function disabling Control Flow Integrity checks due to perf
// impact.
//
// See also:
//   https://clang.llvm.org/docs/ControlFlowIntegrity.html#performance
//   https://www.chromium.org/developers/testing/control-flow-integrity/#overhead-only-tested-on-x64
//
// Usage:
// ```
//   DISABLE_CFI_PERF void Func() {
//     // CFI checks will not be performed in this body, due to perf reasons.
//   }
// ```
#if !defined(DISABLE_CFI_PERF)
#if defined(__clang__) && defined(OFFICIAL_BUILD)
#define DISABLE_CFI_PERF NO_SANITIZE("cfi")
#else
#define DISABLE_CFI_PERF
#endif
#endif

// Annotates a function disabling Control Flow Integrity indirect call checks.
//
// See also:
//   https://clang.llvm.org/docs/ControlFlowIntegrity.html#available-schemes
//   https://www.chromium.org/developers/testing/control-flow-integrity/#indirect-call-failures
//
// Usage:
// ```
//   DISABLE_CFI_ICALL void Func() {
//     // CFI indirect call checks will not be performed in this body.
//   }
// ```
#if !defined(DISABLE_CFI_ICALL)
#if defined(OS_WIN)
#define DISABLE_CFI_ICALL NO_SANITIZE("cfi-icall") __declspec(guard(nocf))
#else
#define DISABLE_CFI_ICALL NO_SANITIZE("cfi-icall")
#endif
#endif

// Evaluates to a string constant containing the function signature.
//
// See also:
//   https://clang.llvm.org/docs/LanguageExtensions.html#source-location-builtins
//   https://en.cppreference.com/w/c/language/function_definition#func
//
// Usage:
// ```
//   void Func(int arg) {
//     std::cout << PRETTY_FUNCTION;  // Prints `void Func(int)` or similar.
//   }
// ```
#if defined(COMPILER_GCC)
#define PRETTY_FUNCTION __PRETTY_FUNCTION__
#elif defined(COMPILER_MSVC)
#define PRETTY_FUNCTION __FUNCSIG__
#else
#define PRETTY_FUNCTION __func__
#endif

// Annotates a variable indicating that its storage should not be filled with a
// fixed pattern when uninitialized.
//
// The `init_stack_vars` gn arg (enabled on most build configs) causes the
// compiler to generate code that writes a fixed pattern into uninitialized
// parts of all local variables, to mitigate security risks. In most cases, e.g.
// when such memory is either never accessed or will be initialized later before
// reading, the compiler is able to remove the additional stores, and any
// remaining stores are unlikely to affect program performance.
//
// If hot code suffers unavoidable perf penalties, this can disable the
// pattern-filling there. This should only be done when necessary, since reads
// from uninitialized variables are not only UB, they can in practice allow
// attackers to control logic by pre-filling the variable's memory with a
// desirable value.
//
// NOTE: This behavior also increases the likelihood the compiler will generate
// `memcpy()`/`memset()` calls to init variables. If this causes link errors for
// targets that don't link against the CRT, this macro can help; you may instead
// want 'configs -= [ "//build/config/compiler:default_init_stack_vars" ]' in
// the relevant .gn file to disable this on the whole target.
//
// See also:
//   https://source.chromium.org/chromium/chromium/src/+/main:build/config/compiler/BUILD.gn;l=3088;drc=24ccaf63ff5b1883be1ebe5f979d917ce28b0131
//   https://clang.llvm.org/docs/ClangCommandLineReference.html#cmdoption-clang-ftrivial-auto-var-init
//   https://clang.llvm.org/docs/AttributeReference.html#uninitialized
//
// Usage:
// ```
//   // The following line declares `i` without ensuring it initially contains
//   // any particular pattern.
//   STACK_UNINITIALIZED int i;
// ```
#if __has_cpp_attribute(clang::uninitialized)
#define STACK_UNINITIALIZED [[clang::uninitialized]]
#elif __has_cpp_attribute(gnu::uninitialized)
#define STACK_UNINITIALIZED [[gnu::uninitialized]]
#else
#define STACK_UNINITIALIZED
#endif

// Annotates a function disabling stack canary checks.
//
// The `-fstack-protector` compiler flag (passed on most non-Windows builds)
// causes the compiler to extend some function prologues and epilogues to set
// and check a canary value, to detect stack buffer overflows and crash in
// response. If hot code suffers unavoidable perf penalties, or intentionally
// modifies the canary value, this can disable the behavior there.
//
// See also:
//   https://clang.llvm.org/docs/ClangCommandLineReference.html#cmdoption-clang-fstack-protector
//   https://clang.llvm.org/docs/AttributeReference.html#no-stack-protector-safebuffers
//
// Usage:
// ```
//   NO_STACK_PROTECTOR void Func() {
//     // Stack canary checks will not be performed in this body.
//   }
// ```
#if __has_cpp_attribute(gnu::no_stack_protector)
#define NO_STACK_PROTECTOR [[gnu::no_stack_protector]]
#elif __has_cpp_attribute(gnu::optimize)
#define NO_STACK_PROTECTOR [[gnu::optimize("-fno-stack-protector")]]
#else
#define NO_STACK_PROTECTOR
#endif

// Annotates a codepath suppressing static analysis along that path. Useful when
// code is safe in practice for reasons the analyzer can't detect, e.g. because
// the condition leading to that path guarantees a param is non-null.
//
// Usage:
// ```
//   if (cond) {
//     ANALYZER_SKIP_THIS_PATH();
//     // Static analysis will be disabled for the remainder of this block.
//     delete ptr;
//   }
// ```
#if defined(__clang_analyzer__)
inline constexpr bool AnalyzerNoReturn()
#if HAS_ATTRIBUTE(analyzer_noreturn)
    __attribute__((analyzer_noreturn))
#endif
{
  return false;
}
#define ANALYZER_SKIP_THIS_PATH() static_cast<void>(::AnalyzerNoReturn())
#else
// The above definition would be safe even outside the analyzer, but defining
// the macro away entirely avoids the need for the optimizer to eliminate it.
#define ANALYZER_SKIP_THIS_PATH()
#endif

// Annotates a condition directing static analysis to assume it is always true.
// Evaluates to the provided `arg` as a `bool`.
//
// Usage:
// ```
//   // Static analysis will assume the following condition always holds.
//   if (ANALYZER_ASSUME_TRUE(cond)) ...
// ```
#if defined(__clang_analyzer__)
inline constexpr bool AnalyzerAssumeTrue(bool arg) {
  return arg || AnalyzerNoReturn();
}
#define ANALYZER_ASSUME_TRUE(arg) ::AnalyzerAssumeTrue(!!(arg))
#else
// Again, the above definition is safe, this is just simpler for the optimizer.
#define ANALYZER_ASSUME_TRUE(arg) (arg)
#endif

// Annotates a function, function pointer, or statement to disallow
// optimizations that merge calls. Useful to ensure the source locations of such
// calls are not obscured.
//
// See also:
//   https://clang.llvm.org/docs/AttributeReference.html#nomerge
//
// Usage:
// ```
//   NOMERGE void Func();  // No direct calls to `Func()` will be merged.
//
//   using Ptr = decltype(&Func);
//   NOMERGE Ptr ptr = &Func;  // No calls through `ptr` will be merged.
//
//   NOMERGE if (cond) {
//     // No calls in this block will be merged.
//   }
// ```
#if __has_cpp_attribute(clang::nomerge)
#define NOMERGE [[clang::nomerge]]
#else
#define NOMERGE
#endif

// Annotates a type as being suitable for passing in registers despite having a
// non-trivial copy or move constructor or destructor. This requires the type
// not be concerned about its address remaining constant, be safely usable after
// copying its memory, and have a destructor that may be safely omitted on
// moved-from instances; an example is `std::unique_ptr`. Unnecessary if the
// copy/move constructor(s) and destructor are unconditionally trivial; likely
// ineffective if the type is too large to be passed in one or two registers
// with the target ABI.
//
// NOTE: Use with caution; this has subtle effects on constructor/destructor
// ordering. When used with types passed or returned by value, values may be
// constructed in the source stack frame, passed in a register, and then used
// and destroyed in the target stack frame.
//
// See also:
//   https://clang.llvm.org/docs/AttributeReference.html#trivial-abi
//   https://libcxx.llvm.org/docs/DesignDocs/UniquePtrTrivialAbi.html
//
// Usage:
// ```
//   // Instances of type `S` will be eligible to be passed in registers despite
//   // `S`'s nontrivial destructor.
//   struct TRIVIAL_ABI S { ~S(); }
// ```
#if __has_cpp_attribute(clang::trivial_abi)
#define TRIVIAL_ABI [[clang::trivial_abi]]
#else
#define TRIVIAL_ABI
#endif

// Annotates a member function as safe to call on a moved-from object, which it
// will reinitialize.
//
// See also:
//   https://clang.llvm.org/extra/clang-tidy/checks/bugprone/use-after-move.html#reinitialization
//
// Usage:
// ```
//   struct S {
//     REINITIALIZES_AFTER_MOVE void Reset();
//   };
//   void Func1(const S&);
//   void Func2() {
//     S s1;
//     S s2 = std::move(s1);
//     s1.Reset();
//     // clang-tidy's `bugprone-use-after-move` check will not flag the
//     // following call as a use-after-move, due to the intervening `Reset()`.
//     Func1(s1);
//   }
// ```
#if __has_cpp_attribute(clang::reinitializes)
#define REINITIALIZES_AFTER_MOVE [[clang::reinitializes]]
#else
#define REINITIALIZES_AFTER_MOVE
#endif

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_COMPILER_SPECIFIC_H_
