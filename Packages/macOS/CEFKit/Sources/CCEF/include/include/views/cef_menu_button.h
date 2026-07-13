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

#ifndef CEF_INCLUDE_VIEWS_CEF_MENU_BUTTON_H_
#define CEF_INCLUDE_VIEWS_CEF_MENU_BUTTON_H_
#pragma once

#include "include/cef_menu_model.h"
#include "include/views/cef_label_button.h"
#include "include/views/cef_menu_button_delegate.h"

///
/// MenuButton is a button with optional text, icon and/or menu marker that
/// shows a menu when clicked with the left mouse button. All size and position
/// values are in density independent pixels (DIP) unless otherwise indicated.
/// Methods must be called on the browser process UI thread unless otherwise
/// indicated.
///
/*--cef(source=library)--*/
class CefMenuButton : public CefLabelButton {
 public:
  ///
  /// Create a new MenuButton. A |delegate| must be provided to call ShowMenu()
  /// when the button is clicked. |text| will be shown on the MenuButton and
  /// used as the default accessible name. If |with_frame| is true the button
  /// will have a visible frame at all times, center alignment, additional
  /// padding and a default minimum size of 70x33 DIP. If |with_frame| is false
  /// the button will only have a visible frame on hover/press, left alignment,
  /// less padding and no default minimum size.
  ///
  /*--cef(optional_param=text)--*/
  static CefRefPtr<CefMenuButton> CreateMenuButton(
      CefRefPtr<CefMenuButtonDelegate> delegate,
      const CefString& text);

  ///
  /// Show a menu with contents |menu_model|. |screen_point| specifies the menu
  /// position in screen coordinates. |anchor_position| specifies how the menu
  /// will be anchored relative to |screen_point|. This method should be called
  /// from CefMenuButtonDelegate::OnMenuButtonPressed().
  ///
  /*--cef()--*/
  virtual void ShowMenu(CefRefPtr<CefMenuModel> menu_model,
                        const CefPoint& screen_point,
                        cef_menu_anchor_position_t anchor_position) = 0;

  ///
  /// Show the menu for this button. Results in a call to
  /// CefMenuButtonDelegate::OnMenuButtonPressed().
  ///
  /*--cef()--*/
  virtual void TriggerMenu() = 0;
};

#endif  // CEF_INCLUDE_VIEWS_CEF_MENU_BUTTON_H_
