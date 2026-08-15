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

#ifndef CEF_INCLUDE_VIEWS_CEF_PANEL_H_
#define CEF_INCLUDE_VIEWS_CEF_PANEL_H_
#pragma once

#include "include/views/cef_panel_delegate.h"
#include "include/views/cef_view.h"

class CefBoxLayout;
class CefFillLayout;
class CefLayout;
class CefWindow;

///
/// A Panel is a container in the views hierarchy that can contain other Views
/// as children. Methods must be called on the browser process UI thread unless
/// otherwise indicated.
///
/*--cef(source=library)--*/
class CefPanel : public CefView {
 public:
  ///
  /// Create a new Panel.
  ///
  /*--cef(optional_param=delegate)--*/
  static CefRefPtr<CefPanel> CreatePanel(CefRefPtr<CefPanelDelegate> delegate);

  ///
  /// Returns this Panel as a Window or NULL if this is not a Window.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefWindow> AsWindow() = 0;

  ///
  /// Set this Panel's Layout to FillLayout and return the FillLayout object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefFillLayout> SetToFillLayout() = 0;

  ///
  /// Set this Panel's Layout to BoxLayout and return the BoxLayout object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBoxLayout> SetToBoxLayout(
      const CefBoxLayoutSettings& settings) = 0;

  ///
  /// Get the Layout.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefLayout> GetLayout() = 0;

  ///
  /// Lay out the child Views (set their bounds based on sizing heuristics
  /// specific to the current Layout).
  ///
  /*--cef()--*/
  virtual void Layout() = 0;

  ///
  /// Add a child View.
  ///
  /*--cef()--*/
  virtual void AddChildView(CefRefPtr<CefView> view) = 0;

  ///
  /// Add a child View at the specified |index|. If |index| matches the result
  /// of GetChildCount() then the View will be added at the end.
  ///
  /*--cef(index_param=index)--*/
  virtual void AddChildViewAt(CefRefPtr<CefView> view, int index) = 0;

  ///
  /// Move the child View to the specified |index|. A negative value for |index|
  /// will move the View to the end.
  ///
  /*--cef()--*/
  virtual void ReorderChildView(CefRefPtr<CefView> view, int index) = 0;

  ///
  /// Remove a child View. The View can then be added to another Panel.
  ///
  /*--cef()--*/
  virtual void RemoveChildView(CefRefPtr<CefView> view) = 0;

  ///
  /// Remove all child Views. The removed Views will be deleted if the client
  /// holds no references to them.
  ///
  /*--cef()--*/
  virtual void RemoveAllChildViews() = 0;

  ///
  /// Returns the number of child Views.
  ///
  /*--cef()--*/
  virtual size_t GetChildViewCount() = 0;

  ///
  /// Returns the child View at the specified |index|.
  ///
  /*--cef(index_param=index)--*/
  virtual CefRefPtr<CefView> GetChildViewAt(int index) = 0;
};

#endif  // CEF_INCLUDE_VIEWS_CEF_PANEL_H_
