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

#ifndef CEF_INCLUDE_VIEWS_CEF_TEXTFIELD_H_
#define CEF_INCLUDE_VIEWS_CEF_TEXTFIELD_H_
#pragma once

#include "include/views/cef_textfield_delegate.h"
#include "include/views/cef_view.h"

///
/// A Textfield supports editing of text. This control is custom rendered with
/// no platform-specific code. Methods must be called on the browser process UI
/// thread unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefTextfield : public CefView {
 public:
  ///
  /// Create a new Textfield.
  ///
  /*--cef(optional_param=delegate)--*/
  static CefRefPtr<CefTextfield> CreateTextfield(
      CefRefPtr<CefTextfieldDelegate> delegate);

  ///
  /// Sets whether the text will be displayed as asterisks.
  ///
  /*--cef()--*/
  virtual void SetPasswordInput(bool password_input) = 0;

  ///
  /// Returns true if the text will be displayed as asterisks.
  ///
  /*--cef()--*/
  virtual bool IsPasswordInput() = 0;

  ///
  /// Sets whether the text will read-only.
  ///
  /*--cef()--*/
  virtual void SetReadOnly(bool read_only) = 0;

  ///
  /// Returns true if the text is read-only.
  ///
  /*--cef()--*/
  virtual bool IsReadOnly() = 0;

  ///
  /// Returns the currently displayed text.
  ///
  /*--cef()--*/
  virtual CefString GetText() = 0;

  ///
  /// Sets the contents to |text|. The cursor will be moved to end of the text
  /// if the current position is outside of the text range.
  ///
  /*--cef()--*/
  virtual void SetText(const CefString& text) = 0;

  ///
  /// Appends |text| to the previously-existing text.
  ///
  /*--cef()--*/
  virtual void AppendText(const CefString& text) = 0;

  ///
  /// Inserts |text| at the current cursor position replacing any selected text.
  ///
  /*--cef()--*/
  virtual void InsertOrReplaceText(const CefString& text) = 0;

  ///
  /// Returns true if there is any selected text.
  ///
  /*--cef()--*/
  virtual bool HasSelection() = 0;

  ///
  /// Returns the currently selected text.
  ///
  /*--cef()--*/
  virtual CefString GetSelectedText() = 0;

  ///
  /// Selects all text. If |reversed| is true the range will end at the logical
  /// beginning of the text; this generally shows the leading portion of text
  /// that overflows its display area.
  ///
  /*--cef()--*/
  virtual void SelectAll(bool reversed) = 0;

  ///
  /// Clears the text selection and sets the caret to the end.
  ///
  /*--cef()--*/
  virtual void ClearSelection() = 0;

  ///
  /// Returns the selected logical text range.
  ///
  /*--cef()--*/
  virtual CefRange GetSelectedRange() = 0;

  ///
  /// Selects the specified logical text range.
  ///
  /*--cef()--*/
  virtual void SelectRange(const CefRange& range) = 0;

  ///
  /// Returns the current cursor position.
  ///
  /*--cef()--*/
  virtual size_t GetCursorPosition() = 0;

  ///
  /// Sets the text color.
  ///
  /*--cef()--*/
  virtual void SetTextColor(cef_color_t color) = 0;

  ///
  /// Returns the text color.
  ///
  /*--cef()--*/
  virtual cef_color_t GetTextColor() = 0;

  ///
  /// Sets the selection text color.
  ///
  /*--cef()--*/
  virtual void SetSelectionTextColor(cef_color_t color) = 0;

  ///
  /// Returns the selection text color.
  ///
  /*--cef()--*/
  virtual cef_color_t GetSelectionTextColor() = 0;

  ///
  /// Sets the selection background color.
  ///
  /*--cef()--*/
  virtual void SetSelectionBackgroundColor(cef_color_t color) = 0;

  ///
  /// Returns the selection background color.
  ///
  /*--cef()--*/
  virtual cef_color_t GetSelectionBackgroundColor() = 0;

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
  /// Applies |color| to the specified |range| without changing the default
  /// color. If |range| is empty the color will be set on the complete text
  /// contents.
  ///
  /*--cef()--*/
  virtual void ApplyTextColor(cef_color_t color, const CefRange& range) = 0;

  ///
  /// Applies |style| to the specified |range| without changing the default
  /// style. If |add| is true the style will be added, otherwise the style will
  /// be removed. If |range| is empty the style will be set on the complete text
  /// contents.
  ///
  /*--cef()--*/
  virtual void ApplyTextStyle(cef_text_style_t style,
                              bool add,
                              const CefRange& range) = 0;

  ///
  /// Returns true if the action associated with the specified command id is
  /// enabled. See additional comments on ExecuteCommand().
  ///
  /*--cef()--*/
  virtual bool IsCommandEnabled(cef_text_field_commands_t command_id) = 0;

  ///
  /// Performs the action associated with the specified command id.
  ///
  /*--cef()--*/
  virtual void ExecuteCommand(cef_text_field_commands_t command_id) = 0;

  ///
  /// Clears Edit history.
  ///
  /*--cef()--*/
  virtual void ClearEditHistory() = 0;

  ///
  /// Sets the placeholder text that will be displayed when the Textfield is
  /// empty.
  ///
  /*--cef()--*/
  virtual void SetPlaceholderText(const CefString& text) = 0;

  ///
  /// Returns the placeholder text that will be displayed when the Textfield is
  /// empty.
  ///
  /*--cef()--*/
  virtual CefString GetPlaceholderText() = 0;

  ///
  /// Sets the placeholder text color.
  ///
  /*--cef()--*/
  virtual void SetPlaceholderTextColor(cef_color_t color) = 0;

  ///
  /// Set the accessible name that will be exposed to assistive technology (AT).
  ///
  /*--cef()--*/
  virtual void SetAccessibleName(const CefString& name) = 0;
};

#endif  // CEF_INCLUDE_VIEWS_CEF_TEXTFIELD_H_
