// Copyright (c) 2011 Marshall A. Greenblatt. Portions copyright (c) 2012
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

/// \file
/// This file adds defines about the platform we're currently building on.
///
/// <pre>
///  Operating System:
///    OS_AIX / OS_ANDROID / OS_ASMJS / OS_FREEBSD / OS_FUCHSIA / OS_IOS /
///    OS_LINUX / OS_MAC / OS_NACL (SFI or NONSFI) / OS_NETBSD / OS_OPENBSD /
///    OS_QNX / OS_SOLARIS / OS_WIN
///  Operating System family:
///    OS_APPLE: IOS or MAC
///    OS_BSD: FREEBSD or NETBSD or OPENBSD
///    OS_POSIX: AIX or ANDROID or ASMJS or CHROMEOS or FREEBSD or IOS or LINUX
///              or MAC or NACL or NETBSD or OPENBSD or QNX or SOLARIS
///
///  /!\ Note: OS_CHROMEOS is set by the build system, not this file
///
///  Compiler:
///    COMPILER_MSVC / COMPILER_GCC
///
///  Processor:
///    ARCH_CPU_ARM64 / ARCH_CPU_ARMEL / ARCH_CPU_MIPS / ARCH_CPU_MIPS64 /
///    ARCH_CPU_MIPS64EL / ARCH_CPU_MIPSEL / ARCH_CPU_PPC64 / ARCH_CPU_S390 /
///    ARCH_CPU_S390X / ARCH_CPU_X86 / ARCH_CPU_X86_64
///  Processor family:
///    ARCH_CPU_ARM_FAMILY: ARMEL or ARM64
///    ARCH_CPU_MIPS_FAMILY: MIPS64EL or MIPSEL or MIPS64 or MIPS
///    ARCH_CPU_PPC64_FAMILY: PPC64
///    ARCH_CPU_S390_FAMILY: S390 or S390X
///    ARCH_CPU_X86_FAMILY: X86 or X86_64
///  Processor features:
///    ARCH_CPU_31_BITS / ARCH_CPU_32_BITS / ARCH_CPU_64_BITS
///    ARCH_CPU_BIG_ENDIAN / ARCH_CPU_LITTLE_ENDIAN
/// </pre>
///

#ifndef CEF_INCLUDE_BASE_CEF_BUILD_H_
#define CEF_INCLUDE_BASE_CEF_BUILD_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "build/build_config.h"
#include "cef/libcef/features/features.h"

// The following #defines are used in cef/include/ headers and CEF client-side
// code. CEF library-side code should use BUILDFLAG checks directly instead of
// these #defines. CEF client-side code will get these #defines from
// cef_config.h so any changes must also be reflected in
// tools/make_config_header.py.

#if BUILDFLAG(IS_LINUX)
#include "ui/base/ozone_buildflags.h"
#if BUILDFLAG(SUPPORTS_OZONE_X11)
#define CEF_X11 1
#endif
#endif

#else  // !USING_CHROMIUM_INCLUDES

#if !defined(GENERATING_CEF_API_HASH)
#include "include/cef_config.h"
#endif

// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

// A set of macros to use for platform detection.
#if defined(ANDROID)
#define OS_ANDROID 1
#elif defined(__APPLE__)
// Only include TargetConditionals after testing ANDROID as some Android builds
// on the Mac have this header available and it's not needed unless the target
// is really an Apple platform.
#include <TargetConditionals.h>
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#define OS_IOS 1
#else
#define OS_MAC 1
// For backwards compatibility.
#define OS_MACOSX 1
#endif  // defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#elif defined(__linux__)
#if !defined(OS_CHROMEOS)
// Do not define OS_LINUX on Chrome OS build.
// The OS_CHROMEOS macro is defined in GN.
#define OS_LINUX 1
#endif  // !defined(OS_CHROMEOS)
// Include a system header to pull in features.h for glibc/uclibc macros.
#include <unistd.h>
#if defined(__GLIBC__) && !defined(__UCLIBC__)
// We really are using glibc, not uClibc pretending to be glibc.
#define LIBC_GLIBC 1
#endif
#elif defined(_WIN32)
#define OS_WIN 1
#elif defined(__Fuchsia__)
#define OS_FUCHSIA 1
#elif defined(__FreeBSD__)
#define OS_FREEBSD 1
#elif defined(__NetBSD__)
#define OS_NETBSD 1
#elif defined(__OpenBSD__)
#define OS_OPENBSD 1
#elif defined(__sun)
#define OS_SOLARIS 1
#elif defined(__QNXNTO__)
#define OS_QNX 1
#elif defined(_AIX)
#define OS_AIX 1
#elif defined(__asmjs__) || defined(__wasm__)
#define OS_ASMJS 1
#else
#error Please add support for your platform in include/base/cef_build.h
#endif
// NOTE: Adding a new port? Please follow
// https://chromium.googlesource.com/chromium/src/+/master/docs/new_port_policy.md

#if defined(OS_MAC) || defined(OS_IOS)
#define OS_APPLE 1
#endif

// For access to standard BSD features, use OS_BSD instead of a
// more specific macro.
#if defined(OS_FREEBSD) || defined(OS_NETBSD) || defined(OS_OPENBSD)
#define OS_BSD 1
#endif

// For access to standard POSIXish features, use OS_POSIX instead of a
// more specific macro.
#if defined(OS_AIX) || defined(OS_ANDROID) || defined(OS_ASMJS) ||  \
    defined(OS_FREEBSD) || defined(OS_IOS) || defined(OS_LINUX) ||  \
    defined(OS_CHROMEOS) || defined(OS_MAC) || defined(OS_NACL) ||  \
    defined(OS_NETBSD) || defined(OS_OPENBSD) || defined(OS_QNX) || \
    defined(OS_SOLARIS)
#define OS_POSIX 1
#endif

// Compiler detection. Note: clang masquerades as GCC on POSIX and as MSVC on
// Windows.
#if defined(__GNUC__)
#define COMPILER_GCC 1
#elif defined(_MSC_VER)
#define COMPILER_MSVC 1
#else
#error Please add support for your compiler in build/build_config.h
#endif

// Processor architecture detection.  For more info on what's defined, see:
//   http://msdn.microsoft.com/en-us/library/b0084kay.aspx
//   http://www.agner.org/optimize/calling_conventions.pdf
//   or with gcc, run: "echo | gcc -E -dM -"
#if defined(_M_X64) || defined(__x86_64__)
#define ARCH_CPU_X86_FAMILY 1
#define ARCH_CPU_X86_64 1
#define ARCH_CPU_64_BITS 1
#define ARCH_CPU_LITTLE_ENDIAN 1
#elif defined(_M_IX86) || defined(__i386__)
#define ARCH_CPU_X86_FAMILY 1
#define ARCH_CPU_X86 1
#define ARCH_CPU_32_BITS 1
#define ARCH_CPU_LITTLE_ENDIAN 1
#elif defined(__s390x__)
#define ARCH_CPU_S390_FAMILY 1
#define ARCH_CPU_S390X 1
#define ARCH_CPU_64_BITS 1
#define ARCH_CPU_BIG_ENDIAN 1
#elif defined(__s390__)
#define ARCH_CPU_S390_FAMILY 1
#define ARCH_CPU_S390 1
#define ARCH_CPU_31_BITS 1
#define ARCH_CPU_BIG_ENDIAN 1
#elif (defined(__PPC64__) || defined(__PPC__)) && defined(__BIG_ENDIAN__)
#define ARCH_CPU_PPC64_FAMILY 1
#define ARCH_CPU_PPC64 1
#define ARCH_CPU_64_BITS 1
#define ARCH_CPU_BIG_ENDIAN 1
#elif defined(__PPC64__)
#define ARCH_CPU_PPC64_FAMILY 1
#define ARCH_CPU_PPC64 1
#define ARCH_CPU_64_BITS 1
#define ARCH_CPU_LITTLE_ENDIAN 1
#elif defined(__ARMEL__)
#define ARCH_CPU_ARM_FAMILY 1
#define ARCH_CPU_ARMEL 1
#define ARCH_CPU_32_BITS 1
#define ARCH_CPU_LITTLE_ENDIAN 1
#elif defined(__aarch64__) || defined(_M_ARM64)
#define ARCH_CPU_ARM_FAMILY 1
#define ARCH_CPU_ARM64 1
#define ARCH_CPU_64_BITS 1
#define ARCH_CPU_LITTLE_ENDIAN 1
#elif defined(__pnacl__) || defined(__asmjs__) || defined(__wasm__)
#define ARCH_CPU_32_BITS 1
#define ARCH_CPU_LITTLE_ENDIAN 1
#elif defined(__MIPSEL__)
#if defined(__LP64__)
#define ARCH_CPU_MIPS_FAMILY 1
#define ARCH_CPU_MIPS64EL 1
#define ARCH_CPU_64_BITS 1
#define ARCH_CPU_LITTLE_ENDIAN 1
#else
#define ARCH_CPU_MIPS_FAMILY 1
#define ARCH_CPU_MIPSEL 1
#define ARCH_CPU_32_BITS 1
#define ARCH_CPU_LITTLE_ENDIAN 1
#endif
#elif defined(__MIPSEB__)
#if defined(__LP64__)
#define ARCH_CPU_MIPS_FAMILY 1
#define ARCH_CPU_MIPS64 1
#define ARCH_CPU_64_BITS 1
#define ARCH_CPU_BIG_ENDIAN 1
#else
#define ARCH_CPU_MIPS_FAMILY 1
#define ARCH_CPU_MIPS 1
#define ARCH_CPU_32_BITS 1
#define ARCH_CPU_BIG_ENDIAN 1
#endif
#else
#error Please add support for your architecture in include/base/cef_build.h
#endif

// Type detection for wchar_t.
#if defined(OS_WIN)
#define WCHAR_T_IS_16_BIT
#elif defined(OS_FUCHSIA)
#define WCHAR_T_IS_32_BIT
#elif defined(OS_POSIX) && defined(COMPILER_GCC) && defined(__WCHAR_MAX__) && \
    (__WCHAR_MAX__ == 0x7fffffff || __WCHAR_MAX__ == 0xffffffff)
#define WCHAR_T_IS_32_BIT
#elif defined(OS_POSIX) && defined(COMPILER_GCC) && defined(__WCHAR_MAX__) && \
    (__WCHAR_MAX__ == 0x7fff || __WCHAR_MAX__ == 0xffff)
// On Posix, we'll detect short wchar_t, but projects aren't guaranteed to
// compile in this mode (in particular, Chrome doesn't). This is intended for
// other projects using base who manage their own dependencies and make sure
// short wchar works for them.
#define WCHAR_T_IS_16_BIT
#else
#error Please add support for your compiler in include/base/cef_build.h
#endif

#if defined(OS_ANDROID)
// The compiler thinks std::string::const_iterator and "const char*" are
// equivalent types.
#define STD_STRING_ITERATOR_IS_CHAR_POINTER
// The compiler thinks std::u16string::const_iterator and "char16_t*" are
// equivalent types.
#define BASE_STRING16_ITERATOR_IS_CHAR16_POINTER
#endif

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_BUILD_H_
