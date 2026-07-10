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

#ifndef CEF_INCLUDE_INTERNAL_CEF_TYPES_OSR_H_
#define CEF_INCLUDE_INTERNAL_CEF_TYPES_OSR_H_
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "include/internal/cef_types_geometry.h"

#ifdef __cplusplus
extern "C" {
#endif

///
/// Structure containing shared texture common metadata.
/// For documentation on each field, please refer to
/// src/media/base/video_frame_metadata.h for actual details.
///
typedef struct _cef_accelerated_paint_info_common_t {
  ///
  /// Size of this structure.
  ///
  size_t size;

  ///
  /// Timestamp of the frame in microseconds since capture start.
  ///
  uint64_t timestamp;

  ///
  /// The full dimensions of the video frame.
  ///
  cef_size_t coded_size;

  ///
  /// The visible area of the video frame.
  ///
  cef_rect_t visible_rect;

  ///
  /// The region of the video frame that capturer would like to populate.
  ///
  cef_rect_t content_rect;

  ///
  /// Full size of the source frame.
  ///
  cef_size_t source_size;

  ///
  /// Updated area of frame, can be considered as the `dirty` area.
  ///
  cef_rect_t capture_update_rect;

  ///
  /// May reflects where the frame's contents originate from if region
  /// capture is used internally.
  ///
  cef_rect_t region_capture_rect;

  ///
  /// The increamental counter of the frame.
  ///
  uint64_t capture_counter;

  ///
  /// Optional flag of capture_update_rect
  ///
  uint8_t has_capture_update_rect;

  ///
  /// Optional flag of region_capture_rect
  ///
  uint8_t has_region_capture_rect;

  ///
  /// Optional flag of source_size
  ///
  uint8_t has_source_size;

  ///
  /// Optional flag of capture_counter
  ///
  uint8_t has_capture_counter;

} cef_accelerated_paint_info_common_t;

#ifdef __cplusplus
}
#endif

#endif  // CEF_INCLUDE_INTERNAL_CEF_TYPES_OSR_H_
