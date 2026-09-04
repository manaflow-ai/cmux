// Copyright (c) 2025 Marshall A. Greenblatt. Portions copyright (c) 2019
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

#ifndef CEF_INCLUDE_BASE_CEF_IMMEDIATE_CRASH_H_
#define CEF_INCLUDE_BASE_CEF_IMMEDIATE_CRASH_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/immediate_crash.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include "include/base/cef_build.h"

#if defined(OS_WIN)
#include <stdlib.h>
#endif

// Crashes in the fastest possible way with no attempt at logging.
// There are several constraints; see http://crbug.com/664209 for more context.
//
// - TRAP_SEQUENCE_() must be fatal. It should not be possible to ignore the
//   resulting exception or simply hit 'continue' to skip over it in a debugger.
// - Different instances of TRAP_SEQUENCE_() must not be folded together, to
//   ensure crash reports are debuggable. Unlike __builtin_trap(), asm volatile
//   blocks will not be folded together.
//   Note: TRAP_SEQUENCE_() previously required an instruction with a unique
//   nonce since unlike clang, GCC folds together identical asm volatile
//   blocks.
// - TRAP_SEQUENCE_() must produce a signal that is distinct from an invalid
//   memory access.
// - TRAP_SEQUENCE_() must be treated as a set of noreturn instructions.
//   __builtin_unreachable() is used to provide that hint here. clang also uses
//   this as a heuristic to pack the instructions in the function epilogue to
//   improve code density.
// - base::ImmediateCrash() is used in allocation hooks. To prevent recursions,
//   TRAP_SEQUENCE_() must not allocate.
//
// Additional properties that are nice to have:
// - TRAP_SEQUENCE_() should be as compact as possible.
// - The first instruction of TRAP_SEQUENCE_() should not change, to avoid
//   shifting crash reporting clusters. As a consequence of this, explicit
//   assembly is preferred over intrinsics.
//   Note: this last bullet point may no longer be true, and may be removed in
//   the future.

// Note: TRAP_SEQUENCE Is currently split into two macro helpers due to the fact
// that clang emits an actual instruction for __builtin_unreachable() on certain
// platforms (see https://crbug.com/958675). In addition, the int3/bkpt/brk will
// be removed in followups, so splitting it up like this now makes it easy to
// land the followups.

#if defined(COMPILER_GCC)

#if defined(ARCH_CPU_X86_FAMILY)

// TODO(crbug.com/40625592): In theory, it should be possible to use just
// int3. However, there are a number of crashes with SIGILL as the exception
// code, so it seems likely that there's a signal handler that allows execution
// to continue after SIGTRAP.
#define TRAP_SEQUENCE1_() asm volatile("int3")

#if defined(OS_APPLE)
// Intentionally empty: __builtin_unreachable() is always part of the sequence
// (see IMMEDIATE_CRASH below) and already emits a ud2 on Mac.
#define TRAP_SEQUENCE2_() asm volatile("")
#else
#define TRAP_SEQUENCE2_() asm volatile("ud2")
#endif  // defined(OS_APPLE)

#elif defined(ARCH_CPU_ARMEL)

// bkpt will generate a SIGBUS when running on armv7 and a SIGTRAP when running
// as a 32 bit userspace app on arm64. There doesn't seem to be any way to
// cause a SIGTRAP from userspace without using a syscall (which would be a
// problem for sandboxing).
// TODO(crbug.com/40625592): Remove bkpt from this sequence.
#define TRAP_SEQUENCE1_() asm volatile("bkpt #0")
#define TRAP_SEQUENCE2_() asm volatile("udf #0")

#elif defined(ARCH_CPU_ARM64)

// This will always generate a SIGTRAP on arm64.
// TODO(crbug.com/40625592): Remove brk from this sequence.
#define TRAP_SEQUENCE1_() asm volatile("brk #0")
#define TRAP_SEQUENCE2_() asm volatile("hlt #0")

#else

// Crash report accuracy will not be guaranteed on other architectures, but at
// least this will crash as expected.
#define TRAP_SEQUENCE1_() __builtin_trap()
#define TRAP_SEQUENCE2_() asm volatile("")

#endif  // ARCH_CPU_*

#elif defined(COMPILER_MSVC)

#if !defined(__clang__)

// MSVC x64 doesn't support inline asm, so use the MSVC intrinsic.
#define TRAP_SEQUENCE1_() __debugbreak()
#define TRAP_SEQUENCE2_()

#elif defined(ARCH_CPU_ARM64)

// Windows ARM64 uses "BRK #F000" as its breakpoint instruction, and
// __debugbreak() generates that in both VC++ and clang.
#define TRAP_SEQUENCE1_() __debugbreak()
// Intentionally empty: __builtin_unreachable() is always part of the sequence
// (see IMMEDIATE_CRASH below) and already emits a ud2 on Win64,
// https://crbug.com/958373
#define TRAP_SEQUENCE2_() __asm volatile("")

#else

#define TRAP_SEQUENCE1_() asm volatile("int3")
#define TRAP_SEQUENCE2_() asm volatile("ud2")

#endif  // __clang__

#else

#error No supported trap sequence!

#endif  // COMPILER_GCC

#define TRAP_SEQUENCE_() \
  do {                   \
    TRAP_SEQUENCE1_();   \
    TRAP_SEQUENCE2_();   \
  } while (false)

// This version of ALWAYS_INLINE inlines even in is_debug=true.
// TODO(pbos): See if NDEBUG can be dropped from ALWAYS_INLINE as well, and if
// so merge. Otherwise document why it cannot inline in debug in
// base/compiler_specific.h.
#if defined(COMPILER_GCC)
#define IMMEDIATE_CRASH_ALWAYS_INLINE inline __attribute__((__always_inline__))
#elif defined(COMPILER_MSVC)
#define IMMEDIATE_CRASH_ALWAYS_INLINE __forceinline
#else
#define IMMEDIATE_CRASH_ALWAYS_INLINE inline
#endif

namespace base {

[[noreturn]] IMMEDIATE_CRASH_ALWAYS_INLINE void ImmediateCrash() {
#if defined(OS_WIN)
  // We can't use abort() on Windows because it results in the
  // abort/retry/ignore dialog which disrupts automated tests.
  // TODO(crbug.com/40948553): investigate if such dialogs can
  // be suppressed
  TRAP_SEQUENCE_();
#if defined(__clang__) || defined(COMPILER_GCC)
  __builtin_unreachable();
#endif  // defined(__clang__) || defined(COMPILER_GCC)
#else   // !defined(OS_WIN)
  abort();
#endif  // !defined(OS_WIN)
}

}  // namespace base

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_IMMEDIATE_CRASH_H_
