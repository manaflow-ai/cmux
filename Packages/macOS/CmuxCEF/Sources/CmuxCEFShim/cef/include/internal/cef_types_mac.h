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

#ifndef CEF_INCLUDE_INTERNAL_CEF_TYPES_MAC_H_
#define CEF_INCLUDE_INTERNAL_CEF_TYPES_MAC_H_
#pragma once

#if !defined(GENERATING_CEF_API_HASH)
#include "include/base/cef_build.h"
#endif

#if defined(OS_MAC)
#include "include/internal/cef_string.h"
#include "include/internal/cef_types_color.h"
#include "include/internal/cef_types_geometry.h"
#include "include/internal/cef_types_osr.h"
#include "include/internal/cef_types_runtime.h"

#define kNullCursorHandle NULL
#define kNullEventHandle NULL
#define kNullWindowHandle NULL

#ifdef __OBJC__
#if __has_feature(objc_arc)
#define CAST_CEF_CURSOR_HANDLE_TO_NSCURSOR(handle) ((__bridge NSCursor*)handle)
#define CAST_CEF_EVENT_HANDLE_TO_NSEVENT(handle) ((__bridge NSEvent*)handle)
#define CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(handle) ((__bridge NSView*)handle)

#define CAST_NSCURSOR_TO_CEF_CURSOR_HANDLE(cursor) ((__bridge void*)cursor)
#define CAST_NSEVENT_TO_CEF_EVENT_HANDLE(event) ((__bridge void*)event)
#define CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(view) ((__bridge void*)view)
#else  // __has_feature(objc_arc)
#define CAST_CEF_CURSOR_HANDLE_TO_NSCURSOR(handle) ((NSCursor*)handle)
#define CAST_CEF_EVENT_HANDLE_TO_NSEVENT(handle) ((NSEvent*)handle)
#define CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(handle) ((NSView*)handle)

#define CAST_NSCURSOR_TO_CEF_CURSOR_HANDLE(cursor) ((void*)cursor)
#define CAST_NSEVENT_TO_CEF_EVENT_HANDLE(event) ((void*)event)
#define CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(view) ((void*)view)
#endif  // __has_feature(objc_arc)
#endif  // __OBJC__

#ifdef __cplusplus
extern "C" {
#endif

// Handle types.
// Actually NSCursor*
typedef void* cef_cursor_handle_t;
// Actually NSEvent*
typedef void* cef_event_handle_t;
// Actually NSView*
typedef void* cef_window_handle_t;
// Actually IOSurface*
typedef void* cef_shared_texture_handle_t;

///
/// Structure representing CefExecuteProcess arguments.
///
typedef struct _cef_main_args_t {
  int argc;
  char** argv;
} cef_main_args_t;

///
/// Class representing window information.
///
typedef struct _cef_window_info_t {
  ///
  /// Size of this structure.
  ///
  size_t size;

  cef_string_t window_name;

  ///
  /// Initial window bounds.
  ///
  cef_rect_t bounds;

  ///
  /// Set to true (1) to create the view initially hidden.
  ///
  int hidden;

  ///
  /// NSView pointer for the parent view.
  ///
  cef_window_handle_t parent_view;

  ///
  /// Set to true (1) to create the browser using windowless (off-screen)
  /// rendering. No view will be created for the browser and all rendering will
  /// occur via the CefRenderHandler interface. The |parent_view| value will be
  /// used to identify monitor info and to act as the parent view for dialogs,
  /// context menus, etc. If |parent_view| is not provided then the main screen
  /// monitor will be used and some functionality that requires a parent view
  /// may not function correctly. In order to create windowless browsers the
  /// CefSettings.windowless_rendering_enabled value must be set to true.
  /// Transparent painting is enabled by default but can be disabled by setting
  /// CefBrowserSettings.background_color to an opaque value.
  ///
  int windowless_rendering_enabled;

  ///
  /// Set to true (1) to enable shared textures for windowless rendering. Only
  /// valid if windowless_rendering_enabled above is also set to true. Currently
  /// only supported on Windows (D3D11).
  ///
  int shared_texture_enabled;

  ///
  /// Set to true (1) to enable the ability to issue BeginFrame from the client
  /// application.
  ///
  int external_begin_frame_enabled;

  ///
  /// NSView pointer for the new browser view. Only used with windowed
  /// rendering.
  ///
  cef_window_handle_t view;

  ///
  /// Optionally change the runtime style. Alloy style will always be used if
  /// |windowless_rendering_enabled| is true or if |parent_view| is provided.
  /// See cef_runtime_style_t documentation for details.
  ///
  cef_runtime_style_t runtime_style;
} cef_window_info_t;

///
/// Structure containing shared texture information for the OnAcceleratedPaint
/// callback. Resources will be released to the underlying pool for reuse when
/// the callback returns from client code.
///
typedef struct _cef_accelerated_paint_info_t {
  ///
  /// Size of this structure.
  ///
  size_t size;

  ///
  /// Handle for the shared texture IOSurface.
  ///
  cef_shared_texture_handle_t shared_texture_io_surface;

  ///
  /// The pixel format of the texture.
  ///
  cef_color_type_t format;

  ///
  /// The extra common info.
  ///
  cef_accelerated_paint_info_common_t extra;
} cef_accelerated_paint_info_t;

#ifdef __cplusplus
}
#endif

#endif  // OS_MAC

#endif  // CEF_INCLUDE_INTERNAL_CEF_TYPES_MAC_H_
