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

#ifndef CEF_INCLUDE_VIEWS_CEF_BOX_LAYOUT_H_
#define CEF_INCLUDE_VIEWS_CEF_BOX_LAYOUT_H_
#pragma once

#include "include/views/cef_layout.h"

class CefView;

///
/// A Layout manager that arranges child views vertically or horizontally in a
/// side-by-side fashion with spacing around and between the child views. The
/// child views are always sized according to their preferred size. If the
/// host's bounds provide insufficient space, child views will be clamped.
/// Excess space will not be distributed. Methods must be called on the browser
/// process UI thread unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefBoxLayout : public CefLayout {
 public:
  ///
  /// Set the flex weight for the given |view|. Using the preferred size as
  /// the basis, free space along the main axis is distributed to views in the
  /// ratio of their flex weights. Similarly, if the views will overflow the
  /// parent, space is subtracted in these ratios. A flex of 0 means this view
  /// is not resized. Flex values must not be negative.
  ///
  /*--cef()--*/
  virtual void SetFlexForView(CefRefPtr<CefView> view, int flex) = 0;

  ///
  /// Clears the flex for the given |view|, causing it to use the default flex
  /// specified via CefBoxLayoutSettings.default_flex.
  ///
  /*--cef()--*/
  virtual void ClearFlexForView(CefRefPtr<CefView> view) = 0;
};

#endif  // CEF_INCLUDE_VIEWS_CEF_BOX_LAYOUT_H_
