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

#ifndef CEF_INCLUDE_CEF_PRINT_HANDLER_H_
#define CEF_INCLUDE_CEF_PRINT_HANDLER_H_
#pragma once

#include "include/cef_base.h"
#include "include/cef_browser.h"
#include "include/cef_print_settings.h"

///
/// Callback interface for asynchronous continuation of print dialog requests.
///
/*--cef(source=library)--*/
class CefPrintDialogCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// Continue printing with the specified |settings|.
  ///
  /*--cef(capi_name=cont)--*/
  virtual void Continue(CefRefPtr<CefPrintSettings> settings) = 0;

  ///
  /// Cancel the printing.
  ///
  /*--cef()--*/
  virtual void Cancel() = 0;
};

///
/// Callback interface for asynchronous continuation of print job requests.
///
/*--cef(source=library)--*/
class CefPrintJobCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// Indicate completion of the print job.
  ///
  /*--cef(capi_name=cont)--*/
  virtual void Continue() = 0;
};

///
/// Implement this interface to handle printing on Linux. Each browser will have
/// only one print job in progress at a time. The methods of this class will be
/// called on the browser process UI thread.
///
/*--cef(source=client)--*/
class CefPrintHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// Called when printing has started for the specified |browser|. This method
  /// will be called before the other OnPrint*() methods and irrespective of how
  /// printing was initiated (e.g. CefBrowserHost::Print(), JavaScript
  /// window.print() or PDF extension print button).
  ///
  /*--cef()--*/
  virtual void OnPrintStart(CefRefPtr<CefBrowser> browser) = 0;

  ///
  /// Synchronize |settings| with client state. If |get_defaults| is true then
  /// populate |settings| with the default print settings. Do not keep a
  /// reference to |settings| outside of this callback.
  ///
  /*--cef()--*/
  virtual void OnPrintSettings(CefRefPtr<CefBrowser> browser,
                               CefRefPtr<CefPrintSettings> settings,
                               bool get_defaults) = 0;

  ///
  /// Show the print dialog. Execute |callback| once the dialog is dismissed.
  /// Return true if the dialog will be displayed or false to cancel the
  /// printing immediately.
  ///
  /*--cef()--*/
  virtual bool OnPrintDialog(CefRefPtr<CefBrowser> browser,
                             bool has_selection,
                             CefRefPtr<CefPrintDialogCallback> callback) = 0;

  ///
  /// Send the print job to the printer. Execute |callback| once the job is
  /// completed. Return true if the job will proceed or false to cancel the job
  /// immediately.
  ///
  /*--cef()--*/
  virtual bool OnPrintJob(CefRefPtr<CefBrowser> browser,
                          const CefString& document_name,
                          const CefString& pdf_file_path,
                          CefRefPtr<CefPrintJobCallback> callback) = 0;

  ///
  /// Reset client state related to printing.
  ///
  /*--cef()--*/
  virtual void OnPrintReset(CefRefPtr<CefBrowser> browser) = 0;

  ///
  /// Return the PDF paper size in device units. Used in combination with
  /// CefBrowserHost::PrintToPDF().
  ///
  /*--cef()--*/
  virtual CefSize GetPdfPaperSize(CefRefPtr<CefBrowser> browser,
                                  int device_units_per_inch) {
    return CefSize();
  }
};

#endif  // CEF_INCLUDE_CEF_PRINT_HANDLER_H_
