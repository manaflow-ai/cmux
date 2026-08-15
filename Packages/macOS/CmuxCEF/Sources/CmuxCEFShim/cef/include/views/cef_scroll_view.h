// Copyright (c) 2016 Marshall A. Greenblatt. All rights reserved.
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
// ---------------------------------------------------------------------------
//
// The contents of this file must follow a specific format in order to
// support the CEF translator tool. See the translator.README.txt file in the
// tools directory for more information.
//

#ifndef CEF_INCLUDE_VIEWS_CEF_SCROLL_VIEW_H_
#define CEF_INCLUDE_VIEWS_CEF_SCROLL_VIEW_H_
#pragma once

#include "include/views/cef_view.h"

///
/// A ScrollView will show horizontal and/or vertical scrollbars when necessary
/// based on the size of the attached content view. Methods must be called on
/// the browser process UI thread unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefScrollView : public CefView {
 public:
  ///
  /// Create a new ScrollView.
  ///
  /*--cef(optional_param=delegate)--*/
  static CefRefPtr<CefScrollView> CreateScrollView(
      CefRefPtr<CefViewDelegate> delegate);

  ///
  /// Set the content View. The content View must have a specified size (e.g.
  /// via CefView::SetBounds or CefViewDelegate::GetPreferredSize).
  ///
  /*--cef()--*/
  virtual void SetContentView(CefRefPtr<CefView> view) = 0;

  ///
  /// Returns the content View.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefView> GetContentView() = 0;

  ///
  /// Returns the visible region of the content View.
  ///
  /*--cef()--*/
  virtual CefRect GetVisibleContentRect() = 0;

  ///
  /// Returns true if the horizontal scrollbar is currently showing.
  ///
  /*--cef()--*/
  virtual bool HasHorizontalScrollbar() = 0;

  ///
  /// Returns the height of the horizontal scrollbar.
  ///
  /*--cef()--*/
  virtual int GetHorizontalScrollbarHeight() = 0;

  ///
  /// Returns true if the vertical scrollbar is currently showing.
  ///
  /*--cef()--*/
  virtual bool HasVerticalScrollbar() = 0;

  ///
  /// Returns the width of the vertical scrollbar.
  ///
  /*--cef()--*/
  virtual int GetVerticalScrollbarWidth() = 0;
};

#endif  // CEF_INCLUDE_VIEWS_CEF_SCROLL_VIEW_H_
