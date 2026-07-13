// Copyright (c) 2021 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_VIEWS_CEF_OVERLAY_CONTROLLER_H_
#define CEF_INCLUDE_VIEWS_CEF_OVERLAY_CONTROLLER_H_
#pragma once

#include "include/cef_base.h"

class CefView;
class CefWindow;

///
/// Controller for an overlay that contains a contents View added via
/// CefWindow::AddOverlayView. Methods exposed by this controller should be
/// called in preference to methods of the same name exposed by the contents
/// View unless otherwise indicated. Methods must be called on the browser
/// process UI thread unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefOverlayController : public CefBaseRefCounted {
 public:
  ///
  /// Returns true if this object is valid.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns true if this object is the same as |that| object.
  ///
  /*--cef()--*/
  virtual bool IsSame(CefRefPtr<CefOverlayController> that) = 0;

  ///
  /// Returns the contents View for this overlay.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefView> GetContentsView() = 0;

  ///
  /// Returns the top-level Window hosting this overlay. Use this method instead
  /// of calling GetWindow() on the contents View.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefWindow> GetWindow() = 0;

  ///
  /// Returns the docking mode for this overlay.
  ///
  /*--cef(default_retval=CEF_DOCKING_MODE_TOP_LEFT)--*/
  virtual cef_docking_mode_t GetDockingMode() = 0;

  ///
  /// Destroy this overlay.
  ///
  /*--cef()--*/
  virtual void Destroy() = 0;

  ///
  /// Sets the bounds (size and position) of this overlay. This will set the
  /// bounds of the contents View to match and trigger a re-layout if necessary.
  /// |bounds| is in parent coordinates and any insets configured on this
  /// overlay will be ignored. Use this method only for overlays created with a
  /// docking mode value of CEF_DOCKING_MODE_CUSTOM. With other docking modes
  /// modify the insets of this overlay and/or layout of the contents View and
  /// call SizeToPreferredSize() instead to calculate the new size and
  /// re-position the overlay if necessary.
  ///
  /*--cef()--*/
  virtual void SetBounds(const CefRect& bounds) = 0;

  ///
  /// Returns the bounds (size and position) of this overlay in parent
  /// coordinates.
  ///
  /*--cef()--*/
  virtual CefRect GetBounds() = 0;

  ///
  /// Returns the bounds (size and position) of this overlay in DIP screen
  /// coordinates.
  ///
  /*--cef()--*/
  virtual CefRect GetBoundsInScreen() = 0;

  ///
  /// Sets the size of this overlay without changing the position. This will set
  /// the size of the contents View to match and trigger a re-layout if
  /// necessary. |size| is in parent coordinates and any insets configured on
  /// this overlay will be ignored. Use this method only for overlays created
  /// with a docking mode value of CEF_DOCKING_MODE_CUSTOM. With other docking
  /// modes modify the insets of this overlay and/or layout of the contents View
  /// and call SizeToPreferredSize() instead to calculate the new size and
  /// re-position the overlay if necessary.
  ///
  /*--cef()--*/
  virtual void SetSize(const CefSize& size) = 0;

  ///
  /// Returns the size of this overlay in parent coordinates.
  ///
  /*--cef()--*/
  virtual CefSize GetSize() = 0;

  ///
  /// Sets the position of this overlay without changing the size. |position| is
  /// in parent coordinates and any insets configured on this overlay will
  /// be ignored. Use this method only for overlays created with a docking mode
  /// value of CEF_DOCKING_MODE_CUSTOM. With other docking modes modify the
  /// insets of this overlay and/or layout of the contents View and call
  /// SizeToPreferredSize() instead to calculate the new size and re-position
  /// the overlay if necessary.
  ///
  /*--cef()--*/
  virtual void SetPosition(const CefPoint& position) = 0;

  ///
  /// Returns the position of this overlay in parent coordinates.
  ///
  /*--cef()--*/
  virtual CefPoint GetPosition() = 0;

  ///
  /// Sets the insets for this overlay. |insets| is in parent coordinates. Use
  /// this method only for overlays created with a docking mode value other than
  /// CEF_DOCKING_MODE_CUSTOM.
  ///
  /*--cef()--*/
  virtual void SetInsets(const CefInsets& insets) = 0;

  ///
  /// Returns the insets for this overlay in parent coordinates.
  ///
  /*--cef()--*/
  virtual CefInsets GetInsets() = 0;

  ///
  /// Size this overlay to its preferred size and trigger a re-layout if
  /// necessary. The position of overlays created with a docking mode value of
  /// CEF_DOCKING_MODE_CUSTOM will not be modified by calling this method. With
  /// other docking modes this method may re-position the overlay if necessary
  /// to accommodate the new size and any insets configured on the contents
  /// View.
  ///
  /*--cef()--*/
  virtual void SizeToPreferredSize() = 0;

  ///
  /// Sets whether this overlay is visible. Overlays are hidden by default. If
  /// this overlay is hidden then it and any child Views will not be drawn and,
  /// if any of those Views currently have focus, then focus will also be
  /// cleared. Painting is scheduled as needed.
  ///
  /*--cef()--*/
  virtual void SetVisible(bool visible) = 0;

  ///
  /// Returns whether this overlay is visible. A View may be visible but still
  /// not drawn in a Window if any parent Views are hidden. Call IsDrawn() to
  /// determine whether this overlay and all parent Views are visible and will
  /// be drawn.
  ///
  /*--cef()--*/
  virtual bool IsVisible() = 0;

  ///
  /// Returns whether this overlay is visible and drawn in a Window. A View is
  /// drawn if it and all parent Views are visible. To determine if the
  /// containing Window is visible to the user on-screen call IsVisible() on the
  /// Window.
  ///
  /*--cef()--*/
  virtual bool IsDrawn() = 0;
};

#endif  // CEF_INCLUDE_VIEWS_CEF_OVERLAY_CONTROLLER_H_
