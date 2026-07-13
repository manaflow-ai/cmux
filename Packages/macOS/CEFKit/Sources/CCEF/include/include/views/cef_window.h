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

#ifndef CEF_INCLUDE_VIEWS_CEF_WINDOW_H_
#define CEF_INCLUDE_VIEWS_CEF_WINDOW_H_
#pragma once

#include "include/cef_image.h"
#include "include/cef_menu_model.h"
#include "include/views/cef_display.h"
#include "include/views/cef_overlay_controller.h"
#include "include/views/cef_panel.h"
#include "include/views/cef_window_delegate.h"

class CefBrowserView;
class CefView;

///
/// A Window is a top-level Window/widget in the Views hierarchy. By default it
/// will have a non-client area with title bar, icon and buttons that supports
/// moving and resizing. All size and position values are in density independent
/// pixels (DIP) unless otherwise indicated. Methods must be called on the
/// browser process UI thread unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefWindow : public CefPanel {
 public:
  ///
  /// Create a new Window.
  ///
  /*--cef(optional_param=delegate)--*/
  static CefRefPtr<CefWindow> CreateTopLevelWindow(
      CefRefPtr<CefWindowDelegate> delegate);

  ///
  /// Show the Window.
  ///
  /*--cef()--*/
  virtual void Show() = 0;

  ///
  /// Show the Window as a browser modal dialog relative to |browser_view|. A
  /// parent Window must be returned via CefWindowDelegate::GetParentWindow()
  /// and |browser_view| must belong to that parent Window. While this Window is
  /// visible, |browser_view| will be disabled while other controls in the
  /// parent Window remain enabled. Navigating or destroying the |browser_view|
  /// will close this Window automatically. Alternately, use Show() and return
  /// true from CefWindowDelegate::IsWindowModalDialog() for a window modal
  /// dialog where all controls in the parent Window are disabled.
  ///
  /*--cef()--*/
  virtual void ShowAsBrowserModalDialog(
      CefRefPtr<CefBrowserView> browser_view) = 0;

  ///
  /// Hide the Window.
  ///
  /*--cef()--*/
  virtual void Hide() = 0;

  ///
  /// Sizes the Window to |size| and centers it in the current display.
  ///
  /*--cef()--*/
  virtual void CenterWindow(const CefSize& size) = 0;

  ///
  /// Close the Window.
  ///
  /*--cef()--*/
  virtual void Close() = 0;

  ///
  /// Returns true if the Window has been closed.
  ///
  /*--cef()--*/
  virtual bool IsClosed() = 0;

  ///
  /// Activate the Window, assuming it already exists and is visible.
  ///
  /*--cef()--*/
  virtual void Activate() = 0;

  ///
  /// Deactivate the Window, making the next Window in the Z order the active
  /// Window.
  ///
  /*--cef()--*/
  virtual void Deactivate() = 0;

  ///
  /// Returns whether the Window is the currently active Window.
  ///
  /*--cef()--*/
  virtual bool IsActive() = 0;

  ///
  /// Bring this Window to the top of other Windows in the Windowing system.
  ///
  /*--cef()--*/
  virtual void BringToTop() = 0;

  ///
  /// Set the Window to be on top of other Windows in the Windowing system.
  ///
  /*--cef()--*/
  virtual void SetAlwaysOnTop(bool on_top) = 0;

  ///
  /// Returns whether the Window has been set to be on top of other Windows in
  /// the Windowing system.
  ///
  /*--cef()--*/
  virtual bool IsAlwaysOnTop() = 0;

  ///
  /// Maximize the Window.
  ///
  /*--cef()--*/
  virtual void Maximize() = 0;

  ///
  /// Minimize the Window.
  ///
  /*--cef()--*/
  virtual void Minimize() = 0;

  ///
  /// Restore the Window.
  ///
  /*--cef()--*/
  virtual void Restore() = 0;

  ///
  /// Set fullscreen Window state. The
  /// CefWindowDelegate::OnWindowFullscreenTransition method will be called
  /// during the fullscreen transition for notification purposes.
  ///
  /*--cef()--*/
  virtual void SetFullscreen(bool fullscreen) = 0;

  ///
  /// Returns true if the Window is maximized.
  ///
  /*--cef()--*/
  virtual bool IsMaximized() = 0;

  ///
  /// Returns true if the Window is minimized.
  ///
  /*--cef()--*/
  virtual bool IsMinimized() = 0;

  ///
  /// Returns true if the Window is fullscreen.
  ///
  /*--cef()--*/
  virtual bool IsFullscreen() = 0;

  ///
  /// Returns the View that currently has focus in this Window, or nullptr if no
  /// View currently has focus. A Window may have a focused View even if it is
  /// not currently active. Any focus changes while a Window is not active may
  /// be applied after that Window next becomes active.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefView> GetFocusedView() = 0;

  ///
  /// Set the Window title.
  ///
  /*--cef(optional_param=title)--*/
  virtual void SetTitle(const CefString& title) = 0;

  ///
  /// Get the Window title.
  ///
  /*--cef()--*/
  virtual CefString GetTitle() = 0;

  ///
  /// Set the Window icon. This should be a 16x16 icon suitable for use in the
  /// Windows's title bar.
  ///
  /*--cef()--*/
  virtual void SetWindowIcon(CefRefPtr<CefImage> image) = 0;

  ///
  /// Get the Window icon.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefImage> GetWindowIcon() = 0;

  ///
  /// Set the Window App icon. This should be a larger icon for use in the host
  /// environment app switching UI. On Windows, this is the ICON_BIG used in
  /// Alt-Tab list and Windows taskbar. The Window icon will be used by default
  /// if no Window App icon is specified.
  ///
  /*--cef()--*/
  virtual void SetWindowAppIcon(CefRefPtr<CefImage> image) = 0;

  ///
  /// Get the Window App icon.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefImage> GetWindowAppIcon() = 0;

  ///
  /// Add a View that will be overlayed on the Window contents with absolute
  /// positioning and high z-order. Positioning is controlled by |docking_mode|
  /// as described below. Setting |can_activate| to true will allow the overlay
  /// view to receive input focus. The returned CefOverlayController object is
  /// used to control the overlay. Overlays are hidden by default.
  ///
  /// With CEF_DOCKING_MODE_CUSTOM:
  ///   1. The overlay is initially hidden, sized to |view|'s preferred size,
  ///      and positioned in the top-left corner.
  ///   2. Optionally change the overlay position and/or size by calling
  ///      CefOverlayController methods.
  ///   3. Call CefOverlayController::SetVisible(true) to show the overlay.
  ///   4. The overlay will be automatically re-sized if |view|'s layout
  ///      changes. Optionally change the overlay position and/or size when
  ///      OnLayoutChanged is called on the Window's delegate to indicate a
  ///      change in Window bounds.
  ///
  /// With other docking modes:
  ///   1. The overlay is initially hidden, sized to |view|'s preferred size,
  ///      and positioned based on |docking_mode|.
  ///   2. Call CefOverlayController::SetVisible(true) to show the overlay.
  ///   3. The overlay will be automatically re-sized if |view|'s layout changes
  ///      and re-positioned as appropriate when the Window resizes.
  ///
  /// Overlays created by this method will receive a higher z-order then any
  /// child Views added previously. It is therefore recommended to call this
  /// method last after all other child Views have been added so that the
  /// overlay displays as the top-most child of the Window.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefOverlayController> AddOverlayView(
      CefRefPtr<CefView> view,
      cef_docking_mode_t docking_mode,
      bool can_activate) = 0;

  ///
  /// Show a menu with contents |menu_model|. |screen_point| specifies the menu
  /// position in screen coordinates. |anchor_position| specifies how the menu
  /// will be anchored relative to |screen_point|.
  ///
  /*--cef()--*/
  virtual void ShowMenu(CefRefPtr<CefMenuModel> menu_model,
                        const CefPoint& screen_point,
                        cef_menu_anchor_position_t anchor_position) = 0;

  ///
  /// Cancel the menu that is currently showing, if any.
  ///
  /*--cef()--*/
  virtual void CancelMenu() = 0;

  ///
  /// Returns the Display that most closely intersects the bounds of this
  /// Window. May return NULL if this Window is not currently displayed.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefDisplay> GetDisplay() = 0;

  ///
  /// Returns the bounds (size and position) of this Window's client area.
  /// Position is in screen coordinates.
  ///
  /*--cef()--*/
  virtual CefRect GetClientAreaBoundsInScreen() = 0;

  ///
  /// Set the regions where mouse events will be intercepted by this Window to
  /// support drag operations. Call this method with an empty vector to clear
  /// the draggable regions. The draggable region bounds should be in window
  /// coordinates.
  ///
  /*--cef(optional_param=regions)--*/
  virtual void SetDraggableRegions(
      const std::vector<CefDraggableRegion>& regions) = 0;

  ///
  /// Retrieve the platform window handle for this Window.
  ///
  /*--cef()--*/
  virtual CefWindowHandle GetWindowHandle() = 0;

  ///
  /// Simulate a key press. |key_code| is the VKEY_* value from Chromium's
  /// ui/events/keycodes/keyboard_codes.h header (VK_* values on Windows).
  /// |event_flags| is some combination of EVENTFLAG_SHIFT_DOWN,
  /// EVENTFLAG_CONTROL_DOWN and/or EVENTFLAG_ALT_DOWN. This method is exposed
  /// primarily for testing purposes.
  ///
  /*--cef()--*/
  virtual void SendKeyPress(int key_code, uint32_t event_flags) = 0;

  ///
  /// Simulate a mouse move. The mouse cursor will be moved to the specified
  /// (screen_x, screen_y) position. This method is exposed primarily for
  /// testing purposes.
  ///
  /*--cef()--*/
  virtual void SendMouseMove(int screen_x, int screen_y) = 0;

  ///
  /// Simulate mouse down and/or mouse up events. |button| is the mouse button
  /// type. If |mouse_down| is true a mouse down event will be sent. If
  /// |mouse_up| is true a mouse up event will be sent. If both are true a mouse
  /// down event will be sent followed by a mouse up event (equivalent to
  /// clicking the mouse button). The events will be sent using the current
  /// cursor position so make sure to call SendMouseMove() first to position the
  /// mouse. This method is exposed primarily for testing purposes.
  ///
  /*--cef()--*/
  virtual void SendMouseEvents(cef_mouse_button_type_t button,
                               bool mouse_down,
                               bool mouse_up) = 0;

  ///
  /// Set the keyboard accelerator for the specified |command_id|. |key_code|
  /// can be any virtual key or character value. Required modifier keys are
  /// specified by |shift_pressed|, |ctrl_pressed| and/or |alt_pressed|.
  /// CefWindowDelegate::OnAccelerator will be called if the keyboard
  /// combination is triggered while this window has focus.
  ///
  /// The |high_priority| value will be considered if a child CefBrowserView has
  /// focus when the keyboard combination is triggered. If |high_priority| is
  /// true then the key event will not be forwarded to the web content
  /// (`keydown` event handler) or CefKeyboardHandler first. If |high_priority|
  /// is false then the behavior will depend on the
  /// CefBrowserView::SetPreferAccelerators configuration.
  ///
  /*--cef()--*/
  virtual void SetAccelerator(int command_id,
                              int key_code,
                              bool shift_pressed,
                              bool ctrl_pressed,
                              bool alt_pressed,
                              bool high_priority) = 0;

  ///
  /// Remove the keyboard accelerator for the specified |command_id|.
  ///
  /*--cef()--*/
  virtual void RemoveAccelerator(int command_id) = 0;

  ///
  /// Remove all keyboard accelerators.
  ///
  /*--cef()--*/
  virtual void RemoveAllAccelerators() = 0;

  ///
  /// Override a standard theme color or add a custom color associated with
  /// |color_id|. See cef_color_ids.h for standard ID values. Recommended usage
  /// is as follows:
  ///
  /// 1. Customize the default native/OS theme by calling SetThemeColor before
  ///    showing the first Window. When done setting colors call
  ///    CefWindow::ThemeChanged to trigger CefViewDelegate::OnThemeChanged
  ///    notifications.
  /// 2. Customize the current native/OS or Chrome theme after it changes by
  ///    calling SetThemeColor from the CefWindowDelegate::OnThemeColorsChanged
  ///    callback. CefViewDelegate::OnThemeChanged notifications will then be
  ///    triggered automatically.
  ///
  /// The configured color will be available immediately via
  /// CefView::GetThemeColor and will be applied to each View in this Window's
  /// component hierarchy when CefViewDelegate::OnThemeChanged is called. See
  /// OnThemeColorsChanged documentation for additional details.
  ///
  /// Clients wishing to add custom colors should use |color_id| values >=
  /// CEF_ChromeColorsEnd.
  ///
  /*--cef()--*/
  virtual void SetThemeColor(int color_id, cef_color_t color) = 0;

  ///
  /// Trigger CefViewDelegate::OnThemeChanged callbacks for each View in this
  /// Window's component hierarchy. Unlike a native/OS or Chrome theme change
  /// this method does not reset theme colors to standard values and does not
  /// result in a call to CefWindowDelegate::OnThemeColorsChanged.
  ///
  /// Do not call this method from CefWindowDelegate::OnThemeColorsChanged or
  /// CefViewDelegate::OnThemeChanged.
  ///
  /*--cef()--*/
  virtual void ThemeChanged() = 0;

  ///
  /// Returns the runtime style for this Window (ALLOY or CHROME). See
  /// cef_runtime_style_t documentation for details.
  ///
  /*--cef(default_retval=CEF_RUNTIME_STYLE_DEFAULT)--*/
  virtual cef_runtime_style_t GetRuntimeStyle() = 0;
};

#endif  // CEF_INCLUDE_VIEWS_CEF_WINDOW_H_
