// Copyright (c) 2022 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_COMMAND_HANDLER_H_
#define CEF_INCLUDE_CEF_COMMAND_HANDLER_H_
#pragma once

#include "include/cef_base.h"
#include "include/cef_browser.h"

///
/// Implement this interface to handle events related to commands. The methods
/// of this class will be called on the UI thread.
///
/*--cef(source=client)--*/
class CefCommandHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// Called to execute a Chrome command triggered via menu selection or
  /// keyboard shortcut. Use the cef_id_for_command_id_name()
  /// function for version-safe mapping of command IDC names from
  /// cef_command_ids.h to version-specific numerical |command_id| values.
  /// |disposition| provides information about the intended command target.
  /// Return true if the command was handled or false for the default
  /// implementation. For context menu commands this will be called after
  /// CefContextMenuHandler::OnContextMenuCommand. Only used with Chrome style.
  ///
  /*--cef()--*/
  virtual bool OnChromeCommand(CefRefPtr<CefBrowser> browser,
                               int command_id,
                               cef_window_open_disposition_t disposition) {
    return false;
  }

  ///
  /// Called to check if a Chrome app menu item should be visible. Use the
  /// cef_id_for_command_id_name() function for version-safe mapping of command
  /// IDC names from cef_command_ids.h to version-specific numerical
  /// |command_id| values. Only called for menu items that would be visible by
  /// default. Only used with Chrome style.
  ///
  /*--cef()--*/
  virtual bool IsChromeAppMenuItemVisible(CefRefPtr<CefBrowser> browser,
                                          int command_id) {
    return true;
  }

  ///
  /// Called to check if a Chrome app menu item should be enabled. Use the
  /// cef_id_for_command_id_name() function for version-safe mapping of command
  /// IDC names from cef_command_ids.h to version-specific numerical
  /// |command_id| values. Only called for menu items that would be enabled by
  /// default. Only used with Chrome style.
  ///
  /*--cef()--*/
  virtual bool IsChromeAppMenuItemEnabled(CefRefPtr<CefBrowser> browser,
                                          int command_id) {
    return true;
  }

  ///
  /// Called during browser creation to check if a Chrome page action icon
  /// should be visible. Only called for icons that would be visible by default.
  /// Only used with Chrome style.
  ///
  /*--cef(optional_param=browser)--*/
  virtual bool IsChromePageActionIconVisible(
      cef_chrome_page_action_icon_type_t icon_type) {
    return true;
  }

  ///
  /// Called during browser creation to check if a Chrome toolbar button
  /// should be visible. Only called for buttons that would be visible by
  /// default. Only used with Chrome style.
  ///
  /*--cef(optional_param=browser)--*/
  virtual bool IsChromeToolbarButtonVisible(
      cef_chrome_toolbar_button_type_t button_type) {
    return true;
  }
};

#endif  // CEF_INCLUDE_CEF_COMMAND_HANDLER_H_
