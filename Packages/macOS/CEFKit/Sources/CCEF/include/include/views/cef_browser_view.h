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

#ifndef CEF_INCLUDE_VIEWS_CEF_BROWSER_VIEW_H_
#define CEF_INCLUDE_VIEWS_CEF_BROWSER_VIEW_H_
#pragma once

#include "include/cef_browser.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_view.h"

///
/// A View hosting a CefBrowser instance. Methods must be called on the browser
/// process UI thread unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefBrowserView : public CefView {
 public:
  ///
  /// Create a new BrowserView. The underlying CefBrowser will not be created
  /// until this view is added to the views hierarchy. The optional |extra_info|
  /// parameter provides an opportunity to specify extra information specific
  /// to the created browser that will be passed to
  /// CefRenderProcessHandler::OnBrowserCreated() in the render process.
  ///
  /*--cef(optional_param=client,optional_param=url,
          optional_param=request_context,optional_param=delegate,
          optional_param=extra_info)--*/
  static CefRefPtr<CefBrowserView> CreateBrowserView(
      CefRefPtr<CefClient> client,
      const CefString& url,
      const CefBrowserSettings& settings,
      CefRefPtr<CefDictionaryValue> extra_info,
      CefRefPtr<CefRequestContext> request_context,
      CefRefPtr<CefBrowserViewDelegate> delegate);

  ///
  /// Returns the BrowserView associated with |browser|.
  ///
  /*--cef()--*/
  static CefRefPtr<CefBrowserView> GetForBrowser(CefRefPtr<CefBrowser> browser);

  ///
  /// Returns the CefBrowser hosted by this BrowserView. Will return NULL if the
  /// browser has not yet been created or has already been destroyed.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBrowser> GetBrowser() = 0;

  ///
  /// Returns the Chrome toolbar associated with this BrowserView. Only
  /// supported when using Chrome style. The CefBrowserViewDelegate::
  /// GetChromeToolbarType() method must return a value other than
  /// CEF_CTT_NONE and the toolbar will not be available until after this
  /// BrowserView is added to a CefWindow and CefViewDelegate::OnWindowChanged()
  /// has been called.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefView> GetChromeToolbar() = 0;

  ///
  /// Sets whether normal priority accelerators are first forwarded to the web
  /// content (`keydown` event handler) or CefKeyboardHandler. Normal priority
  /// accelerators can be registered via CefWindow::SetAccelerator (with
  /// |high_priority|=false) or internally for standard accelerators supported
  /// by Chrome style. If |prefer_accelerators| is true then the matching
  /// accelerator will be triggered immediately (calling
  /// CefWindowDelegate::OnAccelerator or CefCommandHandler::OnChromeCommand
  /// respectively) and the event will not be forwarded to the web content or
  /// CefKeyboardHandler first. If |prefer_accelerators| is false then the
  /// matching accelerator will only be triggered if the event is not handled by
  /// web content (`keydown` event handler that calls `event.preventDefault()`)
  /// or by CefKeyboardHandler. The default value is false.
  ///
  /*--cef()--*/
  virtual void SetPreferAccelerators(bool prefer_accelerators) = 0;

  ///
  /// Returns the runtime style for this BrowserView (ALLOY or CHROME). See
  /// cef_runtime_style_t documentation for details.
  ///
  /*--cef(default_retval=CEF_RUNTIME_STYLE_DEFAULT)--*/
  virtual cef_runtime_style_t GetRuntimeStyle() = 0;
};

#endif  // CEF_INCLUDE_VIEWS_CEF_BROWSER_VIEW_H_
