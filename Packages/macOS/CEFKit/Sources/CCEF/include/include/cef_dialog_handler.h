// Copyright (c) 2012 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_DIALOG_HANDLER_H_
#define CEF_INCLUDE_CEF_DIALOG_HANDLER_H_
#pragma once

#include "include/cef_base.h"
#include "include/cef_browser.h"

///
/// Callback interface for asynchronous continuation of file dialog requests.
///
/*--cef(source=library)--*/
class CefFileDialogCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// Continue the file selection. |file_paths| should be a single value or a
  /// list of values depending on the dialog mode. An empty |file_paths| value
  /// is treated the same as calling Cancel().
  ///
  /*--cef(capi_name=cont,optional_param=file_paths)--*/
  virtual void Continue(const std::vector<CefString>& file_paths) = 0;

  ///
  /// Cancel the file selection.
  ///
  /*--cef()--*/
  virtual void Cancel() = 0;
};

///
/// Implement this interface to handle dialog events. The methods of this class
/// will be called on the browser process UI thread.
///
/*--cef(source=client)--*/
class CefDialogHandler : public virtual CefBaseRefCounted {
 public:
  typedef cef_file_dialog_mode_t FileDialogMode;

  ///
  /// Called to run a file chooser dialog. |mode| represents the type of dialog
  /// to display. |title| to the title to be used for the dialog and may be
  /// empty to show the default title ("Open" or "Save" depending on the mode).
  /// |default_file_path| is the path with optional directory and/or file name
  /// component that should be initially selected in the dialog.
  /// |accept_filters| are used to restrict the selectable file types and may be
  /// any combination of valid lower-cased MIME types (e.g. "text/*" or
  /// "image/*") and individual file extensions (e.g. ".txt" or ".png").
  /// |accept_extensions| provides the semicolon-delimited expansion of MIME
  /// types to file extensions (if known, or empty string otherwise).
  /// |accept_descriptions| provides the descriptions for MIME types (if known,
  /// or empty string otherwise). For example, the "image/*" mime type might
  /// have extensions ".png;.jpg;.bmp;..." and description "Image Files".
  /// |accept_filters|, |accept_extensions| and |accept_descriptions| will all
  /// be the same size. To display a custom dialog return true and execute
  /// |callback| either inline or at a later time. To display the default dialog
  /// return false. If this method returns false it may be called an additional
  /// time for the same dialog (both before and after MIME type expansion).
  ///
  /*--cef(optional_param=title,optional_param=default_file_path,
          optional_param=accept_filters,optional_param=accept_extensions,
          optional_param=accept_descriptions)--*/
  virtual bool OnFileDialog(CefRefPtr<CefBrowser> browser,
                            FileDialogMode mode,
                            const CefString& title,
                            const CefString& default_file_path,
                            const std::vector<CefString>& accept_filters,
                            const std::vector<CefString>& accept_extensions,
                            const std::vector<CefString>& accept_descriptions,
                            CefRefPtr<CefFileDialogCallback> callback) {
    return false;
  }
};

#endif  // CEF_INCLUDE_CEF_DIALOG_HANDLER_H_
