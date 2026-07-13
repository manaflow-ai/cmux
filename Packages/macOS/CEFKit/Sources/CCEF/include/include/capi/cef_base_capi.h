// Copyright (c) 2014 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CAPI_CEF_BASE_CAPI_H_
#define CEF_INCLUDE_CAPI_CEF_BASE_CAPI_H_

#include <stdint.h>

#include "include/internal/cef_export.h"
#include "include/internal/cef_string.h"
#include "include/internal/cef_string_list.h"
#include "include/internal/cef_string_map.h"
#include "include/internal/cef_string_multimap.h"
#include "include/internal/cef_types.h"

#ifdef __cplusplus
extern "C" {
#endif

///
/// All ref-counted framework structures must include this structure first.
///
typedef struct _cef_base_ref_counted_t {
  ///
  /// Size of the data structure.
  ///
  size_t size;

  ///
  /// Called to increment the reference count for the object. Should be called
  /// for every new copy of a pointer to a given object.
  ///
  void(CEF_CALLBACK* add_ref)(struct _cef_base_ref_counted_t* self);

  ///
  /// Called to decrement the reference count for the object. If the reference
  /// count falls to 0 the object should self-delete. Returns true (1) if the
  /// resulting reference count is 0.
  ///
  int(CEF_CALLBACK* release)(struct _cef_base_ref_counted_t* self);

  ///
  /// Returns true (1) if the current reference count is 1.
  ///
  int(CEF_CALLBACK* has_one_ref)(struct _cef_base_ref_counted_t* self);

  ///
  /// Returns true (1) if the current reference count is at least 1.
  ///
  int(CEF_CALLBACK* has_at_least_one_ref)(struct _cef_base_ref_counted_t* self);
} cef_base_ref_counted_t;

///
/// All scoped framework structures must include this structure first.
///
typedef struct _cef_base_scoped_t {
  ///
  /// Size of the data structure.
  ///
  size_t size;

  ///
  /// Called to delete this object. May be NULL if the object is not owned.
  ///
  void(CEF_CALLBACK* del)(struct _cef_base_scoped_t* self);

} cef_base_scoped_t;

#ifdef __cplusplus
}
#endif

#endif  // CEF_INCLUDE_CAPI_CEF_BASE_CAPI_H_
