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

#ifndef CEF_INCLUDE_CEF_VERSION_INFO_H_
#define CEF_INCLUDE_CEF_VERSION_INFO_H_

#include <stddef.h>
#include <string.h>

#include "include/cef_api_hash.h"
#include "include/internal/cef_export.h"

#if !defined(GENERATING_CEF_API_HASH)
#include "include/cef_version.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

///
/// Returns CEF version information for the libcef library. The |entry|
/// parameter describes which version component will be returned:
///
/// 0 - CEF_VERSION_MAJOR
/// 1 - CEF_VERSION_MINOR
/// 2 - CEF_VERSION_PATCH
/// 3 - CEF_COMMIT_NUMBER
/// 4 - CHROME_VERSION_MAJOR
/// 5 - CHROME_VERSION_MINOR
/// 6 - CHROME_VERSION_BUILD
/// 7 - CHROME_VERSION_PATCH
///
CEF_EXPORT int cef_version_info(int entry);

#if CEF_API_ADDED(13800)

///
/// Structure representing all CEF version information.
///
typedef struct _cef_version_info_t {
  ///
  /// Size of this structure.
  ///
  size_t size;

  int cef_version_major;
  int cef_version_minor;
  int cef_version_patch;
  int cef_commit_number;
  int chrome_version_major;
  int chrome_version_minor;
  int chrome_version_build;
  int chrome_version_patch;

#if CEF_API_ADDED(14600)
  ///
  /// Sandbox compatibility hash (Windows only, empty on other platforms).
  ///
  char sandbox_compat_hash[17];
#endif
} cef_version_info_t;

#if CEF_API_ADDED(14600)
///
/// Minimum struct size required to contain the sandbox_compat_hash field.
/// Used for version compatibility checks.
///
#define CEF_VERSION_INFO_SIZE_WITH_SANDBOX_HASH        \
  (offsetof(cef_version_info_t, sandbox_compat_hash) + \
   sizeof(((cef_version_info_t*)0)->sandbox_compat_hash))
#endif

///
/// Return all CEF version information for the libcef library.
///
CEF_EXPORT void cef_version_info_all(cef_version_info_t* info);

#elif !defined(GENERATING_CEF_API_HASH)

// Unversioned definition to support use of the bootstrap and
// CefScopedLibraryLoader with older API versions.
typedef struct _cef_version_info_t {
  // Size of this structure.
  size_t size;

  int cef_version_major;
  int cef_version_minor;
  int cef_version_patch;
  int cef_commit_number;
  int chrome_version_major;
  int chrome_version_minor;
  int chrome_version_build;
  int chrome_version_patch;
} cef_version_info_t;

#endif  // !defined(GENERATING_CEF_API_HASH)

// Helper macro for setting sandbox_compat_hash.
#if CEF_API_ADDED(14600)
#define _CEF_POPULATE_SANDBOX_HASH(info)                        \
  strncpy((info)->sandbox_compat_hash, CEF_SANDBOX_COMPAT_HASH, \
          sizeof((info)->sandbox_compat_hash) - 1);             \
  (info)->sandbox_compat_hash[sizeof((info)->sandbox_compat_hash) - 1] = '\0'
#else
#define _CEF_POPULATE_SANDBOX_HASH(info)
#endif

///
/// Populate CEF version information for the client library.
///
#define CEF_POPULATE_VERSION_INFO(info)                \
  (info)->size = sizeof(cef_version_info_t);           \
  (info)->cef_version_major = CEF_VERSION_MAJOR;       \
  (info)->cef_version_minor = CEF_VERSION_MINOR;       \
  (info)->cef_version_patch = CEF_VERSION_PATCH;       \
  (info)->cef_commit_number = CEF_COMMIT_NUMBER;       \
  (info)->chrome_version_major = CHROME_VERSION_MAJOR; \
  (info)->chrome_version_minor = CHROME_VERSION_MINOR; \
  (info)->chrome_version_build = CHROME_VERSION_BUILD; \
  (info)->chrome_version_patch = CHROME_VERSION_PATCH; \
  _CEF_POPULATE_SANDBOX_HASH(info)

#ifdef __cplusplus
}
#endif

#endif  // CEF_INCLUDE_CEF_VERSION_INFO_H_
