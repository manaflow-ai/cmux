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

#ifndef CEF_INCLUDE_VIEWS_CEF_WINDOW_DELEGATE_H_
#define CEF_INCLUDE_VIEWS_CEF_WINDOW_DELEGATE_H_
#pragma once

#include "include/views/cef_panel_delegate.h"

class CefWindow;

///
/// Implement this interface to handle window events. The methods of this class
/// will be called on the browser process UI thread unless otherwise indicated.
///
/*--cef(source=client)--*/
class CefWindowDelegate : public CefPanelDelegate {
 public:
  ///
  /// Called when |window| is created.
  ///
  /*--cef()--*/
  virtual void OnWindowCreated(CefRefPtr<CefWindow> window) {}

  ///
  /// Called when |window| is closing.
  ///
  /*--cef()--*/
  virtual void OnWindowClosing(CefRefPtr<CefWindow> window) {}

  ///
  /// Called when |window| is destroyed. Release all references to |window| and
  /// do not attempt to execute any methods on |window| after this callback
  /// returns.
  ///
  /*--cef()--*/
  virtual void OnWindowDestroyed(CefRefPtr<CefWindow> window) {}

  ///
  /// Called when |window| is activated or deactivated.
  ///
  /*--cef()--*/
  virtual void OnWindowActivationChanged(CefRefPtr<CefWindow> window,
                                         bool active) {}

  ///
  /// Called when |window| bounds have changed. |new_bounds| will be in DIP
  /// screen coordinates.
  ///
  /*--cef()--*/
  virtual void OnWindowBoundsChanged(CefRefPtr<CefWindow> window,
                                     const CefRect& new_bounds) {}

  ///
  /// Called when |window| is transitioning to or from fullscreen mode. On MacOS
  /// the transition occurs asynchronously with |is_competed| set to false when
  /// the transition starts and true after the transition completes. On other
  /// platforms the transition occurs synchronously with |is_completed| set to
  /// true after the transition completes. With Alloy style you must also
  /// implement CefDisplayHandler::OnFullscreenModeChange to handle fullscreen
  /// transitions initiated by browser content.
  ///
  /*--cef()--*/
  virtual void OnWindowFullscreenTransition(CefRefPtr<CefWindow> window,
                                            bool is_completed) {}

  ///
  /// Return the parent for |window| or NULL if the |window| does not have a
  /// parent. Windows with parents will not get a taskbar button. Set |is_menu|
  /// to true if |window| will be displayed as a menu, in which case it will not
  /// be clipped to the parent window bounds. Set |can_activate_menu| to false
  /// if |is_menu| is true and |window| should not be activated (given keyboard
  /// focus) when displayed.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefWindow> GetParentWindow(CefRefPtr<CefWindow> window,
                                               bool* is_menu,
                                               bool* can_activate_menu) {
    return nullptr;
  }

  ///
  /// Return true if |window| should be created as a window modal dialog. Only
  /// called when a Window is returned via GetParentWindow() with |is_menu| set
  /// to false. All controls in the parent Window will be disabled while
  /// |window| is visible. This functionality is not supported by all Linux
  /// window managers. Alternately, use CefWindow::ShowAsBrowserModalDialog()
  /// for a browser modal dialog that works on all platforms.
  ///
  /*--cef()--*/
  virtual bool IsWindowModalDialog(CefRefPtr<CefWindow> window) {
    return false;
  }

  ///
  /// Return the initial bounds for |window| in density independent pixel (DIP)
  /// coordinates. If this method returns an empty CefRect then
  /// GetPreferredSize() will be called to retrieve the size, and the window
  /// will be placed on the screen with origin (0,0). This method can be used in
  /// combination with CefView::GetBoundsInScreen() to restore the previous
  /// window bounds.
  ///
  /*--cef()--*/
  virtual CefRect GetInitialBounds(CefRefPtr<CefWindow> window) {
    return CefRect();
  }

  ///
  /// Return the initial show state for |window|.
  ///
  /*--cef(default_retval=CEF_SHOW_STATE_NORMAL)--*/
  virtual cef_show_state_t GetInitialShowState(CefRefPtr<CefWindow> window) {
    return CEF_SHOW_STATE_NORMAL;
  }

  ///
  /// Return true if |window| should be created without a frame or title bar.
  /// The window will be resizable if CanResize() returns true. Use
  /// CefWindow::SetDraggableRegions() to specify draggable regions.
  ///
  /*--cef()--*/
  virtual bool IsFrameless(CefRefPtr<CefWindow> window) { return false; }

  ///
  /// Return true if |window| should be created with standard window buttons
  /// like close, minimize and zoom. This method is only supported on macOS.
  ///
  /*--cef()--*/
  virtual bool WithStandardWindowButtons(CefRefPtr<CefWindow> window) {
    return !IsFrameless(window);
  }

  ///
  /// Return whether the titlebar height should be overridden, and sets the
  /// height of the titlebar in |titlebar_height|. On macOS, it can also be used
  /// to adjust the vertical position of the traffic light buttons in frameless
  /// windows. The buttons will be positioned halfway down the titlebar at a
  /// height of |titlebar_height| / 2.
  ///
  /*--cef()--*/
  virtual bool GetTitlebarHeight(CefRefPtr<CefWindow> window,
                                 float* titlebar_height) {
    return false;
  }

  ///
  /// Return whether the view should accept the initial mouse-down event,
  /// allowing it to respond to click-through behavior. If STATE_ENABLED is
  /// returned, the view will be sent a mouseDown: message for an initial
  /// mouse-down event, activating the view with one click, instead of clicking
  /// first to make the window active and then clicking the view.
  ///
  /// This method is only supported on macOS. For more details, refer to the
  /// documentation of acceptsFirstMouse.
  ///
  /*--cef(default_retval=STATE_DEFAULT)--*/
  virtual cef_state_t AcceptsFirstMouse(CefRefPtr<CefWindow> window) {
    return STATE_DEFAULT;
  }

  ///
  /// Return true if |window| can be resized.
  ///
  /*--cef()--*/
  virtual bool CanResize(CefRefPtr<CefWindow> window) { return true; }

  ///
  /// Return true if |window| can be maximized.
  ///
  /*--cef()--*/
  virtual bool CanMaximize(CefRefPtr<CefWindow> window) { return true; }

  ///
  /// Return true if |window| can be minimized.
  ///
  /*--cef()--*/
  virtual bool CanMinimize(CefRefPtr<CefWindow> window) { return true; }

  ///
  /// Return true if |window| can be closed. This will be called for user-
  /// initiated window close actions and when CefWindow::Close() is called.
  ///
  /*--cef()--*/
  virtual bool CanClose(CefRefPtr<CefWindow> window) { return true; }

  ///
  /// Called when a keyboard accelerator registered with
  /// CefWindow::SetAccelerator is triggered. Return true if the accelerator was
  /// handled or false otherwise.
  ///
  /*--cef()--*/
  virtual bool OnAccelerator(CefRefPtr<CefWindow> window, int command_id) {
    return false;
  }

  ///
  /// Called after all other controls in the window have had a chance to
  /// handle the event. |event| contains information about the keyboard event.
  /// Return true if the keyboard event was handled or false otherwise.
  ///
  /*--cef()--*/
  virtual bool OnKeyEvent(CefRefPtr<CefWindow> window,
                          const CefKeyEvent& event) {
    return false;
  }

  ///
  /// Called after the native/OS or Chrome theme for |window| has changed.
  /// |chrome_theme| will be true if the notification is for a Chrome theme.
  ///
  /// Native/OS theme colors are configured globally and do not need to be
  /// customized for each Window individually. An example of a native/OS theme
  /// change that triggers this callback is when the user switches between dark
  /// and light mode during application lifespan. Native/OS theme changes can be
  /// disabled by passing the `--force-dark-mode` or `--force-light-mode`
  /// command-line flag.
  ///
  /// Chrome theme colors will be applied and this callback will be triggered
  /// if/when a BrowserView is added to the Window's component hierarchy. Chrome
  /// theme colors can be configured on a per-RequestContext basis using
  /// CefRequestContext::SetChromeColorScheme or (Chrome style only) by
  /// visiting chrome://settings/manageProfile. Any theme changes using those
  /// mechanisms will also trigger this callback. Chrome theme colors will be
  /// persisted and restored from disk cache.
  ///
  /// This callback is not triggered on Window creation so clients that wish to
  /// customize the initial native/OS theme must call CefWindow::SetThemeColor
  /// and CefWindow::ThemeChanged before showing the first Window.
  ///
  /// Theme colors will be reset to standard values before this callback is
  /// called for the first affected Window. Call CefWindow::SetThemeColor from
  /// inside this callback to override a standard color or add a custom color.
  /// CefViewDelegate::OnThemeChanged will be called after this callback for the
  /// complete |window| component hierarchy.
  ///
  /*--cef()--*/
  virtual void OnThemeColorsChanged(CefRefPtr<CefWindow> window,
                                    bool chrome_theme) {}

  ///
  /// Optionally change the runtime style for this Window. See
  /// cef_runtime_style_t documentation for details.
  ///
  /*--cef(default_retval=CEF_RUNTIME_STYLE_DEFAULT)--*/
  virtual cef_runtime_style_t GetWindowRuntimeStyle() {
    return CEF_RUNTIME_STYLE_DEFAULT;
  }

  ///
  /// Return Linux-specific window properties for correctly handling by window
  /// managers
  ///
  /*--cef()--*/
  virtual bool GetLinuxWindowProperties(CefRefPtr<CefWindow> window,
                                        CefLinuxWindowProperties& properties) {
    return false;
  }
};

#endif  // CEF_INCLUDE_VIEWS_CEF_WINDOW_DELEGATE_H_
