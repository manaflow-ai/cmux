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

#ifndef CEF_INCLUDE_CEF_IMAGE_H_
#define CEF_INCLUDE_CEF_IMAGE_H_
#pragma once

#include "include/cef_base.h"
#include "include/cef_values.h"

///
/// Container for a single image represented at different scale factors. All
/// image representations should be the same size in density independent pixel
/// (DIP) units. For example, if the image at scale factor 1.0 is 100x100 pixels
/// then the image at scale factor 2.0 should be 200x200 pixels -- both images
/// will display with a DIP size of 100x100 units. The methods of this class can
/// be called on any browser process thread.
///
/*--cef(source=library)--*/
class CefImage : public virtual CefBaseRefCounted {
 public:
  ///
  /// Create a new CefImage. It will initially be empty. Use the Add*() methods
  /// to add representations at different scale factors.
  ///
  /*--cef()--*/
  static CefRefPtr<CefImage> CreateImage();

  ///
  /// Returns true if this Image is empty.
  ///
  /*--cef()--*/
  virtual bool IsEmpty() = 0;

  ///
  /// Returns true if this Image and |that| Image share the same underlying
  /// storage. Will also return true if both images are empty.
  ///
  /*--cef()--*/
  virtual bool IsSame(CefRefPtr<CefImage> that) = 0;

  ///
  /// Add a bitmap image representation for |scale_factor|. Only 32-bit
  /// RGBA/BGRA formats are supported. |pixel_width| and |pixel_height| are the
  /// bitmap representation size in pixel coordinates. |pixel_data| is the array
  /// of pixel data and should be |pixel_width| x |pixel_height| x 4 bytes in
  /// size. |color_type| and |alpha_type| values specify the pixel format.
  ///
  /*--cef()--*/
  virtual bool AddBitmap(float scale_factor,
                         int pixel_width,
                         int pixel_height,
                         cef_color_type_t color_type,
                         cef_alpha_type_t alpha_type,
                         const void* pixel_data,
                         size_t pixel_data_size) = 0;

  ///
  /// Add a PNG image representation for |scale_factor|. |png_data| is the image
  /// data of size |png_data_size|. Any alpha transparency in the PNG data will
  /// be maintained.
  ///
  /*--cef()--*/
  virtual bool AddPNG(float scale_factor,
                      const void* png_data,
                      size_t png_data_size) = 0;

  ///
  /// Create a JPEG image representation for |scale_factor|. |jpeg_data| is the
  /// image data of size |jpeg_data_size|. The JPEG format does not support
  /// transparency so the alpha byte will be set to 0xFF for all pixels.
  ///
  /*--cef()--*/
  virtual bool AddJPEG(float scale_factor,
                       const void* jpeg_data,
                       size_t jpeg_data_size) = 0;

  ///
  /// Returns the image width in density independent pixel (DIP) units.
  ///
  /*--cef()--*/
  virtual size_t GetWidth() = 0;

  ///
  /// Returns the image height in density independent pixel (DIP) units.
  ///
  /*--cef()--*/
  virtual size_t GetHeight() = 0;

  ///
  /// Returns true if this image contains a representation for |scale_factor|.
  ///
  /*--cef()--*/
  virtual bool HasRepresentation(float scale_factor) = 0;

  ///
  /// Removes the representation for |scale_factor|. Returns true on success.
  ///
  /*--cef()--*/
  virtual bool RemoveRepresentation(float scale_factor) = 0;

  ///
  /// Returns information for the representation that most closely matches
  /// |scale_factor|. |actual_scale_factor| is the actual scale factor for the
  /// representation. |pixel_width| and |pixel_height| are the representation
  /// size in pixel coordinates. Returns true on success.
  ///
  /*--cef()--*/
  virtual bool GetRepresentationInfo(float scale_factor,
                                     float& actual_scale_factor,
                                     int& pixel_width,
                                     int& pixel_height) = 0;

  ///
  /// Returns the bitmap representation that most closely matches
  /// |scale_factor|. Only 32-bit RGBA/BGRA formats are supported. |color_type|
  /// and |alpha_type| values specify the desired output pixel format.
  /// |pixel_width| and |pixel_height| are the output representation size in
  /// pixel coordinates. Returns a CefBinaryValue containing the pixel data on
  /// success or NULL on failure.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBinaryValue> GetAsBitmap(float scale_factor,
                                                cef_color_type_t color_type,
                                                cef_alpha_type_t alpha_type,
                                                int& pixel_width,
                                                int& pixel_height) = 0;

  ///
  /// Returns the PNG representation that most closely matches |scale_factor|.
  /// If |with_transparency| is true any alpha transparency in the image will be
  /// represented in the resulting PNG data. |pixel_width| and |pixel_height|
  /// are the output representation size in pixel coordinates. Returns a
  /// CefBinaryValue containing the PNG image data on success or NULL on
  /// failure.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBinaryValue> GetAsPNG(float scale_factor,
                                             bool with_transparency,
                                             int& pixel_width,
                                             int& pixel_height) = 0;

  ///
  /// Returns the JPEG representation that most closely matches |scale_factor|.
  /// |quality| determines the compression level with 0 == lowest and 100 ==
  /// highest. The JPEG format does not support alpha transparency and the alpha
  /// channel, if any, will be discarded. |pixel_width| and |pixel_height| are
  /// the output representation size in pixel coordinates. Returns a
  /// CefBinaryValue containing the JPEG image data on success or NULL on
  /// failure.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBinaryValue> GetAsJPEG(float scale_factor,
                                              int quality,
                                              int& pixel_width,
                                              int& pixel_height) = 0;
};

#endif  // CEF_INCLUDE_CEF_IMAGE_H_
