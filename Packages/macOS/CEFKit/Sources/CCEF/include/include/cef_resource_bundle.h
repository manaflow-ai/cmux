// Copyright (c) 2015 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_RESOURCE_BUNDLE_H_
#define CEF_INCLUDE_CEF_RESOURCE_BUNDLE_H_
#pragma once

#include "include/cef_base.h"
#include "include/cef_values.h"

///
/// Class used for retrieving resources from the resource bundle (*.pak) files
/// loaded by CEF during startup or via the CefResourceBundleHandler returned
/// from CefApp::GetResourceBundleHandler. See CefSettings for additional
/// options related to resource bundle loading. The methods of this class may be
/// called on any thread unless otherwise indicated.
///
/*--cef(source=library,no_debugct_check)--*/
class CefResourceBundle : public virtual CefBaseRefCounted {
 public:
  typedef cef_scale_factor_t ScaleFactor;

  ///
  /// Returns the global resource bundle instance.
  ///
  /*--cef()--*/
  static CefRefPtr<CefResourceBundle> GetGlobal();

  ///
  /// Returns the localized string for the specified |string_id| or an empty
  /// string if the value is not found. Use the cef_id_for_pack_string_name()
  /// function for version-safe mapping of string IDS names from
  /// cef_pack_strings.h to version-specific numerical |string_id| values.
  ///
  /*--cef()--*/
  virtual CefString GetLocalizedString(int string_id) = 0;

  ///
  /// Returns a CefBinaryValue containing the decompressed contents of the
  /// specified scale independent |resource_id| or NULL if not found. Use the
  /// cef_id_for_pack_resource_name() function for version-safe mapping of
  /// resource IDR names from cef_pack_resources.h to version-specific numerical
  /// |resource_id| values.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBinaryValue> GetDataResource(int resource_id) = 0;

  ///
  /// Returns a CefBinaryValue containing the decompressed contents of the
  /// specified |resource_id| nearest the scale factor |scale_factor| or NULL if
  /// not found. Use a |scale_factor| value of SCALE_FACTOR_NONE for scale
  /// independent resources or call GetDataResource instead. Use the
  /// cef_id_for_pack_resource_name() function for version-safe mapping of
  /// resource IDR names from cef_pack_resources.h to version-specific numerical
  /// |resource_id| values.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBinaryValue> GetDataResourceForScale(
      int resource_id,
      ScaleFactor scale_factor) = 0;
};

#endif  // CEF_INCLUDE_CEF_RESOURCE_BUNDLE_H_
