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

#ifndef CEF_INCLUDE_VIEWS_CEF_DISPLAY_H_
#define CEF_INCLUDE_VIEWS_CEF_DISPLAY_H_
#pragma once

#include <vector>

#include "include/cef_base.h"

///
/// This class typically, but not always, corresponds to a physical display
/// connected to the system. A fake Display may exist on a headless system, or a
/// Display may correspond to a remote, virtual display. All size and position
/// values are in density independent pixel (DIP) coordinates unless otherwise
/// indicated. Methods must be called on the browser process UI thread unless
/// otherwise indicated.
///
/// For details on coordinate systems and usage see
/// https://chromiumembedded.github.io/cef/general_usage#coordinate-systems
///
/*--cef(source=library)--*/
class CefDisplay : public CefBaseRefCounted {
 public:
  ///
  /// Returns the primary Display.
  ///
  /*--cef()--*/
  static CefRefPtr<CefDisplay> GetPrimaryDisplay();

  ///
  /// Returns the Display nearest |point|. Set |input_pixel_coords| to true if
  /// |point| is in pixel screen coordinates instead of DIP screen coordinates.
  ///
  /*--cef()--*/
  static CefRefPtr<CefDisplay> GetDisplayNearestPoint(const CefPoint& point,
                                                      bool input_pixel_coords);

  ///
  /// Returns the Display that most closely intersects |bounds|.  Set
  /// |input_pixel_coords| to true if |bounds| is in pixel screen coordinates
  /// instead of DIP screen coordinates.
  ///
  /*--cef()--*/
  static CefRefPtr<CefDisplay> GetDisplayMatchingBounds(
      const CefRect& bounds,
      bool input_pixel_coords);

  ///
  /// Returns the total number of Displays. Mirrored displays are excluded; this
  /// method is intended to return the number of distinct, usable displays.
  ///
  /*--cef()--*/
  static size_t GetDisplayCount();

  ///
  /// Returns all Displays. Mirrored displays are excluded; this method is
  /// intended to return distinct, usable displays.
  ///
  /*--cef(count_func=displays:GetDisplayCount)--*/
  static void GetAllDisplays(std::vector<CefRefPtr<CefDisplay>>& displays);

  ///
  /// Convert |point| from DIP screen coordinates to pixel screen coordinates.
  /// This method is only used on Windows.
  ///
  /*--cef()--*/
  static CefPoint ConvertScreenPointToPixels(const CefPoint& point);

  ///
  /// Convert |point| from pixel screen coordinates to DIP screen coordinates.
  /// This method is only used on Windows.
  ///
  /*--cef()--*/
  static CefPoint ConvertScreenPointFromPixels(const CefPoint& point);

  ///
  /// Convert |rect| from DIP screen coordinates to pixel screen coordinates.
  /// This method is only used on Windows.
  ///
  /*--cef()--*/
  static CefRect ConvertScreenRectToPixels(const CefRect& rect);

  ///
  /// Convert |rect| from pixel screen coordinates to DIP screen coordinates.
  /// This method is only used on Windows.
  ///
  /*--cef()--*/
  static CefRect ConvertScreenRectFromPixels(const CefRect& rect);

  ///
  /// Returns the unique identifier for this Display.
  ///
  /*--cef()--*/
  virtual int64_t GetID() = 0;

  ///
  /// Returns this Display's device pixel scale factor. This specifies how much
  /// the UI should be scaled when the actual output has more pixels than
  /// standard displays (which is around 100~120dpi). The potential return
  /// values differ by platform. Windowed browsers with 1.0 zoom will have a
  /// JavaScript `window.devicePixelRatio` value matching the associated
  /// Display's GetDeviceScaleFactor() value.
  ///
  /*--cef()--*/
  virtual float GetDeviceScaleFactor() = 0;

  ///
  /// Convert |point| from DIP coordinates to pixel coordinates using this
  /// Display's device scale factor.
  ///
  /*--cef()--*/
  virtual void ConvertPointToPixels(CefPoint& point) = 0;

  ///
  /// Convert |point| from pixel coordinates to DIP coordinates using this
  /// Display's device scale factor.
  ///
  /*--cef()--*/
  virtual void ConvertPointFromPixels(CefPoint& point) = 0;

  ///
  /// Returns this Display's bounds in DIP screen coordinates. This is the full
  /// size of the display.
  ///
  /*--cef()--*/
  virtual CefRect GetBounds() = 0;

  ///
  /// Returns this Display's work area in DIP screen coordinates. This excludes
  /// areas of the display that are occupied with window manager toolbars, etc.
  ///
  /*--cef()--*/
  virtual CefRect GetWorkArea() = 0;

  ///
  /// Returns this Display's rotation in degrees.
  ///
  /*--cef()--*/
  virtual int GetRotation() = 0;
};

#endif  // CEF_INCLUDE_VIEWS_CEF_DISPLAY_H_
