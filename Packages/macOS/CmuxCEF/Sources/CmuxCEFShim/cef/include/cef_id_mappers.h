// Copyright (c) 2025 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_ID_MAPPERS_H_
#define CEF_INCLUDE_CEF_ID_MAPPERS_H_
#pragma once

///
/// Helper for declaring a static IDR variable.
///
#define CEF_DECLARE_PACK_RESOURCE_ID(name) \
  static const int name = cef_id_for_pack_resource_name(#name)

///
/// Helper for declaring a static IDS variable.
///
#define CEF_DECLARE_PACK_STRING_ID(name) \
  static const int name = cef_id_for_pack_string_name(#name)

///
/// Helper for declaring a static IDC variable.
///
#define CEF_DECLARE_COMMAND_ID(name) \
  static const int name = cef_id_for_command_id_name(#name)

#ifdef __cplusplus
extern "C" {
#endif

#include "include/internal/cef_export.h"

///
/// Returns the numeric ID value for an IDR |name| from cef_pack_resources.h or
/// -1 if |name| is unrecognized by the current CEF/Chromium build. This
/// function provides version-safe mapping of resource IDR names to
/// version-specific numeric ID values. Numeric ID values are likely to change
/// across CEF/Chromium versions but names generally remain the same.
///
CEF_EXPORT int cef_id_for_pack_resource_name(const char* name);

///
/// Returns the numeric ID value for an IDS |name| from cef_pack_strings.h or -1
/// if |name| is unrecognized by the current CEF/Chromium build. This function
/// provides version-safe mapping of string IDS names to version-specific
/// numeric ID values. Numeric ID values are likely to change across
/// CEF/Chromium versions but names generally remain the same.
///
CEF_EXPORT int cef_id_for_pack_string_name(const char* name);

///
/// Returns the numeric ID value for an IDC |name| from cef_command_ids.h or -1
/// if |name| is unrecognized by the current CEF/Chromium build. This function
/// provides version-safe mapping of command IDC names to version-specific
/// numeric ID values. Numeric ID values are likely to change across
/// CEF/Chromium versions but names generally remain the same.
///
CEF_EXPORT int cef_id_for_command_id_name(const char* name);

#ifdef __cplusplus
}
#endif

#endif  // CEF_INCLUDE_CEF_ID_MAPPERS_H_
