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

#ifndef CEF_INCLUDE_VIEWS_CEF_VIEW_DELEGATE_H_
#define CEF_INCLUDE_VIEWS_CEF_VIEW_DELEGATE_H_
#pragma once

#include "include/cef_base.h"

class CefView;

///
/// Implement this interface to handle view events. All size and position values
/// are in density independent pixels (DIP) unless otherwise indicated. The
/// methods of this class will be called on the browser process UI thread unless
/// otherwise indicated.
///
/*--cef(source=client)--*/
class CefViewDelegate : public virtual CefBaseRefCounted {
 public:
  ///
  /// Return the preferred size for |view|. The Layout will use this information
  /// to determine the display size.
  ///
  /*--cef()--*/
  virtual CefSize GetPreferredSize(CefRefPtr<CefView> view) {
    return CefSize();
  }

  ///
  /// Return the minimum size for |view|.
  ///
  /*--cef()--*/
  virtual CefSize GetMinimumSize(CefRefPtr<CefView> view) { return CefSize(); }

  ///
  /// Return the maximum size for |view|.
  ///
  /*--cef()--*/
  virtual CefSize GetMaximumSize(CefRefPtr<CefView> view) { return CefSize(); }

  ///
  /// Return the height necessary to display |view| with the provided |width|.
  /// If not specified the result of GetPreferredSize().height will be used by
  /// default. Override if |view|'s preferred height depends upon the width
  /// (for example, with Labels).
  ///
  /*--cef()--*/
  virtual int GetHeightForWidth(CefRefPtr<CefView> view, int width) {
    return 0;
  }

  ///
  /// Called when the parent of |view| has changed. If |view| is being added to
  /// |parent| then |added| will be true. If |view| is being removed from
  /// |parent| then |added| will be false. If |view| is being reparented the
  /// remove notification will be sent before the add notification. Do not
  /// modify the view hierarchy in this callback.
  ///
  /*--cef()--*/
  virtual void OnParentViewChanged(CefRefPtr<CefView> view,
                                   bool added,
                                   CefRefPtr<CefView> parent) {}

  ///
  /// Called when a child of |view| has changed. If |child| is being added to
  /// |view| then |added| will be true. If |child| is being removed from |view|
  /// then |added| will be false. If |child| is being reparented the remove
  /// notification will be sent to the old parent before the add notification is
  /// sent to the new parent. Do not modify the view hierarchy in this callback.
  ///
  /*--cef()--*/
  virtual void OnChildViewChanged(CefRefPtr<CefView> view,
                                  bool added,
                                  CefRefPtr<CefView> child) {}

  ///
  /// Called when |view| is added or removed from the CefWindow.
  ///
  /*--cef()--*/
  virtual void OnWindowChanged(CefRefPtr<CefView> view, bool added) {}

  ///
  /// Called when the layout of |view| has changed.
  ///
  /*--cef()--*/
  virtual void OnLayoutChanged(CefRefPtr<CefView> view,
                               const CefRect& new_bounds) {}

  ///
  /// Called when |view| gains focus.
  ///
  /*--cef()--*/
  virtual void OnFocus(CefRefPtr<CefView> view) {}

  ///
  /// Called when |view| loses focus.
  ///
  /*--cef()--*/
  virtual void OnBlur(CefRefPtr<CefView> view) {}

  ///
  /// Called when the theme for |view| has changed, after the new theme colors
  /// have already been applied. Views are notified via the component hierarchy
  /// in depth-first reverse order (children before parents).
  ///
  /// This will be called in the following cases:
  ///
  /// 1. When |view|, or a parent of |view|, is added to a Window.
  /// 2. When the native/OS or Chrome theme changes for the Window that contains
  ///    |view|. See CefWindowDelegate::OnThemeColorsChanged documentation.
  /// 3. When the client explicitly calls CefWindow::ThemeChanged on the Window
  ///    that contains |view|.
  ///
  /// Optionally use this callback to override the new per-View theme colors by
  /// calling CefView::SetBackgroundColor or the appropriate component-specific
  /// method. See CefWindow::SetThemeColor documentation for how to customize
  /// additional Window theme colors.
  ///
  /*--cef()--*/
  virtual void OnThemeChanged(CefRefPtr<CefView> view) {}
};

#endif  // CEF_INCLUDE_VIEWS_CEF_WINDOW_DELEGATE_H_
