// Copyright (c) 2022 Marshall A. Greenblatt. All rights reserved.
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
// THIS FILE IS FOR TESTING PURPOSES ONLY.
//
// The APIs defined in this file are for testing purposes only. They should only
// be included from unit test targets.
//

#ifndef CEF_INCLUDE_TEST_CEF_TEST_SERVER_H_
#define CEF_INCLUDE_TEST_CEF_TEST_SERVER_H_
#pragma once

#if !defined(BUILDING_CEF_SHARED) && !defined(WRAPPING_CEF_SHARED) && \
    !defined(UNIT_TEST)
#error This file can be included for unit tests only
#endif

#include <map>

#include "include/cef_base.h"
#include "include/cef_request.h"

class CefTestServerConnection;
class CefTestServerHandler;

///
/// Class representing an embedded test server that supports HTTP/HTTPS
/// requests. This is a basic server providing only an essential subset of the
/// HTTP/1.1 protocol. Especially, it assumes that the request syntax is
/// correct. It *does not* support a Chunked Transfer Encoding. Server capacity
/// is limited and is intended to handle only a small number of simultaneous
/// connections (e.g. for communicating between applications on localhost). The
/// methods of this class are safe to call from any thread in the brower process
/// unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefTestServer : public CefBaseRefCounted {
 public:
  ///
  /// Create and start a new test server that binds to |port|. If |port| is 0 an
  /// available port number will be selected. If |https_server| is true the
  /// server will be HTTPS, otherwise it will be HTTP. When |https_server| is
  /// true the |https_cert_type| value is used to configure the certificate
  /// type. Returns the newly created server object on success, or nullptr if
  /// the server cannot be started.
  ///
  /// A new thread will be created for each CreateAndStart call (the "dedicated
  /// server thread"). It is therefore recommended to use a different
  /// CefTestServerHandler instance for each CreateAndStart call to avoid thread
  /// safety issues in the CefTestServerHandler implementation.
  ///
  /// On success, this method will block until the dedicated server thread has
  /// started. The server will continue running until Stop is called.
  ///
  /*--cef()--*/
  static CefRefPtr<CefTestServer> CreateAndStart(
      uint16_t port,
      bool https_server,
      cef_test_cert_type_t https_cert_type,
      CefRefPtr<CefTestServerHandler> handler);

  ///
  /// Stop the server and shut down the dedicated server thread. This method
  /// must be called on the same thread as CreateAndStart. It will block until
  /// the dedicated server thread has shut down.
  ///
  /*--cef()--*/
  virtual void Stop() = 0;

  ///
  /// Returns the server origin including the port number (e.g.
  /// "[http|https]://127.0.0.1:<port>".
  ///
  /*--cef()--*/
  virtual CefString GetOrigin() = 0;
};

///
/// Implement this interface to handle test server requests. A new thread will
/// be created for each CefTestServer::CreateAndStart call (the "dedicated
/// server thread"), and the methods of this class will be called on that
/// thread. See related documentation on CefTestServer::CreateAndStart.
///
/*--cef(source=client)--*/
class CefTestServerHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// Called when |server| receives a request. To handle the request return true
  /// and use |connection| to send the response either synchronously or
  /// asynchronously. Otherwise, return false if the request is unhandled. When
  /// returning false do not call any |connection| methods.
  ///
  /*--cef()--*/
  virtual bool OnTestServerRequest(
      CefRefPtr<CefTestServer> server,
      CefRefPtr<CefRequest> request,
      CefRefPtr<CefTestServerConnection> connection) = 0;
};

///
/// Class representing a test server connection. The methods of this class are
/// safe to call from any thread in the brower process unless otherwise
/// indicated.
///
/*--cef(source=library)--*/
class CefTestServerConnection : public CefBaseRefCounted {
 public:
  typedef std::multimap<CefString, CefString> HeaderMap;

  ///
  /// Send an HTTP 200 "OK" response. |content_type| is the response content
  /// type (e.g. "text/html"). |data| is the response content and |data_size| is
  /// the size of |data| in bytes. The contents of |data| will be copied. The
  /// connection will be closed automatically after the response is sent.
  ///
  /*--cef()--*/
  virtual void SendHttp200Response(const CefString& content_type,
                                   const void* data,
                                   size_t data_size) = 0;

  ///
  /// Send an HTTP 404 "Not Found" response. The connection will be closed
  /// automatically after the response is sent.
  ///
  /*--cef()--*/
  virtual void SendHttp404Response() = 0;

  ///
  /// Send an HTTP 500 "Internal Server Error" response. |error_message| is the
  /// associated error message. The connection will be closed automatically
  /// after the response is sent.
  ///
  /*--cef()--*/
  virtual void SendHttp500Response(const CefString& error_message) = 0;

  ///
  /// Send a custom HTTP response. |response_code| is the HTTP response code
  /// sent in the status line (e.g. 200). |content_type| is the response content
  /// type (e.g. "text/html"). |data| is the response content and |data_size| is
  /// the size of |data| in bytes. The contents of |data| will be copied.
  /// |extra_headers| is an optional map of additional header key/value pairs.
  /// The connection will be closed automatically after the response is sent.
  ///
  /*--cef(optional_param=extra_headers)--*/
  virtual void SendHttpResponse(int response_code,
                                const CefString& content_type,
                                const void* data,
                                size_t data_size,
                                const HeaderMap& extra_headers) = 0;
};

#endif  // CEF_INCLUDE_TEST_CEF_TEST_SERVER_H_
