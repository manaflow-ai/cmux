// Copyright (c) 2020 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_DEVTOOLS_MESSAGE_OBSERVER_H_
#define CEF_INCLUDE_CEF_DEVTOOLS_MESSAGE_OBSERVER_H_
#pragma once

#include "include/cef_base.h"

class CefBrowser;

///
/// Callback interface for CefBrowserHost::AddDevToolsMessageObserver. The
/// methods of this class will be called on the browser process UI thread.
///
/*--cef(source=client)--*/
class CefDevToolsMessageObserver : public virtual CefBaseRefCounted {
 public:
  ///
  /// Method that will be called on receipt of a DevTools protocol message.
  /// |browser| is the originating browser instance. |message| is a UTF8-encoded
  /// JSON dictionary representing either a method result or an event. |message|
  /// is only valid for the scope of this callback and should be copied if
  /// necessary. Return true if the message was handled or false if the message
  /// should be further processed and passed to the OnDevToolsMethodResult or
  /// OnDevToolsEvent methods as appropriate.
  ///
  /// Method result dictionaries include an "id" (int) value that identifies the
  /// orginating method call sent from CefBrowserHost::SendDevToolsMessage, and
  /// optionally either a "result" (dictionary) or "error" (dictionary) value.
  /// The "error" dictionary will contain "code" (int) and "message" (string)
  /// values. Event dictionaries include a "method" (string) value and
  /// optionally a "params" (dictionary) value. See the DevTools protocol
  /// documentation at https://chromedevtools.github.io/devtools-protocol/ for
  /// details of supported method calls and the expected "result" or "params"
  /// dictionary contents. JSON dictionaries can be parsed using the
  /// CefParseJSON function if desired, however be aware of performance
  /// considerations when parsing large messages (some of which may exceed 1MB
  /// in size).
  ///
  /*--cef()--*/
  virtual bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser,
                                 const void* message,
                                 size_t message_size) {
    return false;
  }

  ///
  /// Method that will be called after attempted execution of a DevTools
  /// protocol method. |browser| is the originating browser instance.
  /// |message_id| is the "id" value that identifies the originating method call
  /// message. If the method succeeded |success| will be true and |result| will
  /// be the UTF8-encoded JSON "result" dictionary value (which may be empty).
  /// If the method failed |success| will be false and |result| will be the
  /// UTF8-encoded JSON "error" dictionary value. |result| is only valid for the
  /// scope of this callback and should be copied if necessary. See the
  /// OnDevToolsMessage documentation for additional details on |result|
  /// contents.
  ///
  /*--cef(optional_param=result)--*/
  virtual void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                                      int message_id,
                                      bool success,
                                      const void* result,
                                      size_t result_size) {}

  ///
  /// Method that will be called on receipt of a DevTools protocol event.
  /// |browser| is the originating browser instance. |method| is the "method"
  /// value. |params| is the UTF8-encoded JSON "params" dictionary value (which
  /// may be empty). |params| is only valid for the scope of this callback and
  /// should be copied if necessary. See the OnDevToolsMessage documentation for
  /// additional details on |params| contents.
  ///
  /*--cef(optional_param=params)--*/
  virtual void OnDevToolsEvent(CefRefPtr<CefBrowser> browser,
                               const CefString& method,
                               const void* params,
                               size_t params_size) {}

  ///
  /// Method that will be called when the DevTools agent has attached. |browser|
  /// is the originating browser instance. This will generally occur in response
  /// to the first message sent while the agent is detached.
  ///
  /*--cef()--*/
  virtual void OnDevToolsAgentAttached(CefRefPtr<CefBrowser> browser) {}

  ///
  /// Method that will be called when the DevTools agent has detached. |browser|
  /// is the originating browser instance. Any method results that were pending
  /// before the agent became detached will not be delivered, and any active
  /// event subscriptions will be canceled.
  ///
  /*--cef()--*/
  virtual void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) {}
};

#endif  // CEF_INCLUDE_CEF_DEVTOOLS_MESSAGE_OBSERVER_H_
