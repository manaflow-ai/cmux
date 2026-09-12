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

#ifndef CEF_INCLUDE_VIEWS_CEF_LABEL_BUTTON_H_
#define CEF_INCLUDE_VIEWS_CEF_LABEL_BUTTON_H_
#pragma once

#include "include/cef_image.h"
#include "include/views/cef_button.h"
#include "include/views/cef_button_delegate.h"

class CefMenuButton;

///
/// LabelButton is a button with optional text and/or icon. Methods must be
/// called on the browser process UI thread unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefLabelButton : public CefButton {
 public:
  ///
  /// Create a new LabelButton. A |delegate| must be provided to handle the
  /// button click. |text| will be shown on the LabelButton and used as the
  /// default accessible name.
  ///
  /*--cef(optional_param=text)--*/
  static CefRefPtr<CefLabelButton> CreateLabelButton(
      CefRefPtr<CefButtonDelegate> delegate,
      const CefString& text);

  ///
  /// Returns this LabelButton as a MenuButton or NULL if this is not a
  /// MenuButton.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefMenuButton> AsMenuButton() = 0;

  ///
  /// Sets the text shown on the LabelButton. By default |text| will also be
  /// used as the accessible name.
  ///
  /*--cef()--*/
  virtual void SetText(const CefString& text) = 0;

  ///
  /// Returns the text shown on the LabelButton.
  ///
  /*--cef()--*/
  virtual CefString GetText() = 0;

  ///
  /// Sets the image shown for |button_state|. When this Button is drawn if no
  /// image exists for the current state then the image for
  /// CEF_BUTTON_STATE_NORMAL, if any, will be shown.
  ///
  /*--cef(optional_param=image)--*/
  virtual void SetImage(cef_button_state_t button_state,
                        CefRefPtr<CefImage> image) = 0;

  ///
  /// Returns the image shown for |button_state|. If no image exists for that
  /// state then the image for CEF_BUTTON_STATE_NORMAL will be returned.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefImage> GetImage(cef_button_state_t button_state) = 0;

  ///
  /// Sets the text color shown for the specified button |for_state| to |color|.
  ///
  /*--cef()--*/
  virtual void SetTextColor(cef_button_state_t for_state,
                            cef_color_t color) = 0;

  ///
  /// Sets the text colors shown for the non-disabled states to |color|.
  ///
  /*--cef()--*/
  virtual void SetEnabledTextColors(cef_color_t color) = 0;

  ///
  /// Sets the font list. The format is "<FONT_FAMILY_LIST>,[STYLES] <SIZE>",
  /// where:
  /// - FONT_FAMILY_LIST is a comma-separated list of font family names,
  /// - STYLES is an optional space-separated list of style names
  ///   (case-sensitive "Bold" and "Italic" are supported), and
  /// - SIZE is an integer font size in pixels with the suffix "px".
  ///
  /// Here are examples of valid font description strings:
  /// - "Arial, Helvetica, Bold Italic 14px"
  /// - "Arial, 14px"
  ///
  /*--cef()--*/
  virtual void SetFontList(const CefString& font_list) = 0;

  ///
  /// Sets the horizontal alignment; reversed in RTL. Default is
  /// CEF_HORIZONTAL_ALIGNMENT_CENTER.
  ///
  /*--cef()--*/
  virtual void SetHorizontalAlignment(cef_horizontal_alignment_t alignment) = 0;

  ///
  /// Reset the minimum size of this LabelButton to |size|.
  ///
  /*--cef()--*/
  virtual void SetMinimumSize(const CefSize& size) = 0;

  ///
  /// Reset the maximum size of this LabelButton to |size|.
  ///
  /*--cef()--*/
  virtual void SetMaximumSize(const CefSize& size) = 0;
};

#endif  // CEF_INCLUDE_VIEWS_CEF_LABEL_BUTTON_H_
