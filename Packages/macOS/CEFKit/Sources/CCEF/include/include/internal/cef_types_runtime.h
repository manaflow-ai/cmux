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

#ifndef CEF_INCLUDE_INTERNAL_CEF_TYPES_RUNTIME_H_
#define CEF_INCLUDE_INTERNAL_CEF_TYPES_RUNTIME_H_
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

///
/// CEF supports both a Chrome runtime style (based on the Chrome UI layer) and
/// an Alloy runtime style (based on the Chromium content layer). Chrome style
/// provides the full Chrome UI and browser functionality whereas Alloy style
/// provides less default browser functionality but adds additional client
/// callbacks and support for windowless (off-screen) rendering. The style type
/// is individually configured for each window/browser at creation time and
/// different styles can be mixed during runtime. For additional comparative
/// details on runtime styles see
/// https://chromiumembedded.github.io/cef/architecture#cef3
///
/// Windowless rendering will always use Alloy style. Windowed rendering with a
/// default window or client-provided parent window can configure the style via
/// CefWindowInfo.runtime_style. Windowed rendering with the Views framework can
/// configure the style via CefWindowDelegate::GetWindowRuntimeStyle and
/// CefBrowserViewDelegate::GetBrowserRuntimeStyle. Alloy style Windows with the
/// Views framework can host only Alloy style BrowserViews but Chrome style
/// Windows can host both style BrowserViews. Additionally, a Chrome style
/// Window can host at most one Chrome style BrowserView but potentially
/// multiple Alloy style BrowserViews. See CefWindowInfo.runtime_style
/// documentation for any additional platform-specific limitations.
///
typedef enum {
  ///
  /// Use the default style. See above documentation for exceptions.
  ///
  CEF_RUNTIME_STYLE_DEFAULT,

  ///
  /// Use Chrome style.
  ///
  CEF_RUNTIME_STYLE_CHROME,

  ///
  /// Use Alloy style.
  ///
  CEF_RUNTIME_STYLE_ALLOY,
} cef_runtime_style_t;

#ifdef __cplusplus
}
#endif

#endif  // CEF_INCLUDE_INTERNAL_CEF_TYPES_RUNTIME_H_
