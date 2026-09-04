// Copyright (c) 2014 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_PRINT_SETTINGS_H_
#define CEF_INCLUDE_CEF_PRINT_SETTINGS_H_
#pragma once

#include <vector>

#include "include/cef_base.h"

///
/// Class representing print settings.
///
/*--cef(source=library)--*/
class CefPrintSettings : public virtual CefBaseRefCounted {
 public:
  typedef cef_color_model_t ColorModel;
  typedef cef_duplex_mode_t DuplexMode;
  typedef std::vector<CefRange> PageRangeList;

  ///
  /// Create a new CefPrintSettings object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefPrintSettings> Create();

  ///
  /// Returns true if this object is valid. Do not call any other methods if
  /// this function returns false.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns true if the values of this object are read-only. Some APIs may
  /// expose read-only objects.
  ///
  /*--cef()--*/
  virtual bool IsReadOnly() = 0;

  ///
  /// Set the page orientation.
  ///
  /*--cef()--*/
  virtual void SetOrientation(bool landscape) = 0;

  ///
  /// Returns true if the orientation is landscape.
  ///
  /*--cef()--*/
  virtual bool IsLandscape() = 0;

  ///
  /// Set the printer printable area in device units.
  /// Some platforms already provide flipped area. Set |landscape_needs_flip|
  /// to false on those platforms to avoid double flipping.
  ///
  /*--cef()--*/
  virtual void SetPrinterPrintableArea(
      const CefSize& physical_size_device_units,
      const CefRect& printable_area_device_units,
      bool landscape_needs_flip) = 0;

  ///
  /// Set the device name.
  ///
  /*--cef(optional_param=name)--*/
  virtual void SetDeviceName(const CefString& name) = 0;

  ///
  /// Get the device name.
  ///
  /*--cef()--*/
  virtual CefString GetDeviceName() = 0;

  ///
  /// Set the DPI (dots per inch).
  ///
  /*--cef()--*/
  virtual void SetDPI(int dpi) = 0;

  ///
  /// Get the DPI (dots per inch).
  ///
  /*--cef()--*/
  virtual int GetDPI() = 0;

  ///
  /// Set the page ranges.
  ///
  /*--cef()--*/
  virtual void SetPageRanges(const PageRangeList& ranges) = 0;

  ///
  /// Returns the number of page ranges that currently exist.
  ///
  /*--cef()--*/
  virtual size_t GetPageRangesCount() = 0;

  ///
  /// Retrieve the page ranges.
  ///
  /*--cef(count_func=ranges:GetPageRangesCount)--*/
  virtual void GetPageRanges(PageRangeList& ranges) = 0;

  ///
  /// Set whether only the selection will be printed.
  ///
  /*--cef()--*/
  virtual void SetSelectionOnly(bool selection_only) = 0;

  ///
  /// Returns true if only the selection will be printed.
  ///
  /*--cef()--*/
  virtual bool IsSelectionOnly() = 0;

  ///
  /// Set whether pages will be collated.
  ///
  /*--cef()--*/
  virtual void SetCollate(bool collate) = 0;

  ///
  /// Returns true if pages will be collated.
  ///
  /*--cef()--*/
  virtual bool WillCollate() = 0;

  ///
  /// Set the color model.
  ///
  /*--cef()--*/
  virtual void SetColorModel(ColorModel model) = 0;

  ///
  /// Get the color model.
  ///
  /*--cef(default_retval=COLOR_MODEL_UNKNOWN)--*/
  virtual ColorModel GetColorModel() = 0;

  ///
  /// Set the number of copies.
  ///
  /*--cef()--*/
  virtual void SetCopies(int copies) = 0;

  ///
  /// Get the number of copies.
  ///
  /*--cef()--*/
  virtual int GetCopies() = 0;

  ///
  /// Set the duplex mode.
  ///
  /*--cef()--*/
  virtual void SetDuplexMode(DuplexMode mode) = 0;

  ///
  /// Get the duplex mode.
  ///
  /*--cef(default_retval=DUPLEX_MODE_UNKNOWN)--*/
  virtual DuplexMode GetDuplexMode() = 0;
};

#endif  // CEF_INCLUDE_CEF_PRINT_SETTINGS_H_
