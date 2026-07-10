// Copyright (c) 2024 Marshall A. Greenblatt. All rights reserved.
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
// Versions are managed using the version_manager.py tool. For usage details
// see
// https://chromiumembedded.github.io/cef/api_versioning
//

#ifndef CEF_INCLUDE_CEF_API_HASH_H_
#define CEF_INCLUDE_CEF_API_HASH_H_

#include "include/internal/cef_export.h"

#if !defined(GENERATING_CEF_API_HASH)
#include "include/cef_api_versions.h"
#endif

// Experimental CEF API. Experimental API is unversioned, meaning that it is
// excluded (compiled out) when clients explicitly set the CEF_API_VERSION
// value in their project configuration. Experimental API is not back/forward
// compatible with different CEF versions.
#define CEF_API_VERSION_EXPERIMENTAL 999999

// Placeholder for the next CEF version currently under development. This is a
// temporary value that must be replaced with the actual next version number
// (output of running `version_manager.py -n`) prior to upstream merge. As an
// added reminder, use of this value will cause version_manager.py to fail when
// computing hashes for explicit API versions. When adding new API consider
// using CEF_API_VERSION_EXPERIMENTAL instead.
#if !defined(CEF_API_VERSION_NEXT)
#define CEF_API_VERSION_NEXT 999998
#endif

// Shorter versions of the above for convenience use in comparison macros.
#define CEF_NEXT CEF_API_VERSION_NEXT
#define CEF_EXPERIMENTAL CEF_API_VERSION_EXPERIMENTAL

// API version that will be compiled client-side. The experimental (unversioned)
// API is selected by default. Clients can set the CEF_API_VERSION value in
// their project configuration to configure an explicit API version. Unlike
// the experimental API, explicit API versions are back/forward compatible with
// a specific range of CEF versions.
#if !defined(CEF_API_VERSION)
#define CEF_API_VERSION CEF_API_VERSION_EXPERIMENTAL
#endif

#if !defined(GENERATING_CEF_API_HASH)
#if CEF_API_VERSION < CEF_API_VERSION_MIN ||                                  \
    (CEF_API_VERSION > CEF_API_VERSION_LAST && CEF_API_VERSION != CEF_NEXT && \
     CEF_API_VERSION != CEF_EXPERIMENTAL)
#error Building with unsupported CEF_API_VERSION value
#endif
#endif

#define _CEF_AH_PASTE(a, b) a##_##b
#define _CEF_AH_EVAL(a, b) _CEF_AH_PASTE(a, b)
#define _CEF_AH_DECLARE(version) _CEF_AH_EVAL(CEF_API_HASH, version)

// API hashes for the selected CEF_API_VERSION. API hashes are created for
// each version by analyzing CEF header files for C API type definitions. The
// hash value will change when header files are modified in a way that may
// cause binary incompatibility with other builds.
#define CEF_API_HASH_PLATFORM _CEF_AH_DECLARE(CEF_API_VERSION)

#if defined(BUILDING_CEF_SHARED)

#define _CEF_AV_LT(v) 1
#define _CEF_AV_GE(v) 1

#else  // !defined(BUILDING_CEF_SHARED)

#define _CEF_AV_CMP(v, op) (CEF_API_VERSION op v)

#define _CEF_AV_LT(v) _CEF_AV_CMP(v, <)
#define _CEF_AV_GE(v) _CEF_AV_CMP(v, >=)

#endif  // !defined(BUILDING_CEF_SHARED)

///
/// API was added in the specified version.
///
#define CEF_API_ADDED(v) _CEF_AV_GE(v)

///
/// API was removed in the specified version.
///
#define CEF_API_REMOVED(v) _CEF_AV_LT(v)

///
/// API exists only in the specified version range.
///
#define CEF_API_RANGE(va, vr) (_CEF_AV_GE(va) && _CEF_AV_LT(vr))

#ifdef __cplusplus
extern "C" {
#endif

///
/// Configures the CEF API version and returns API hashes for the libcef
/// library. The returned string is owned by the library and should not be
/// freed. The |version| parameter should be CEF_API_VERSION and any changes to
/// this value will be ignored after the first call to this method. The |entry|
/// parameter describes which hash value will be returned:
///
/// 0 - CEF_API_HASH_PLATFORM
/// 1 - CEF_API_HASH_UNIVERSAL (deprecated, same as CEF_API_HASH_PLATFORM)
/// 2 - CEF_COMMIT_HASH (from cef_version.h)
/// 3 - CEF_SANDBOX_COMPAT_HASH (from cef_version.h, Windows only)
///
CEF_EXPORT const char* cef_api_hash(int version, int entry);

///
/// Returns the CEF API version that was configured by the first call to
/// cef_api_hash().
///
CEF_EXPORT int cef_api_version();

#ifdef __cplusplus
}
#endif

#endif  // CEF_INCLUDE_CEF_API_HASH_H_
