// Copyright (c) 2017 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_SERVER_H_
#define CEF_INCLUDE_CEF_SERVER_H_
#pragma once

#include <map>

#include "include/cef_base.h"
#include "include/cef_callback.h"
#include "include/cef_request.h"
#include "include/cef_task.h"

class CefServerHandler;

///
/// Class representing a server that supports HTTP and WebSocket requests.
/// Server capacity is limited and is intended to handle only a small number of
/// simultaneous connections (e.g. for communicating between applications on
/// localhost). The methods of this class are safe to call from any thread in
/// the brower process unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefServer : public CefBaseRefCounted {
 public:
  typedef std::multimap<CefString, CefString> HeaderMap;

  ///
  /// Create a new server that binds to |address| and |port|. |address| must be
  /// a valid IPv4 or IPv6 address (e.g. 127.0.0.1 or ::1) and |port| must be a
  /// port number outside of the reserved range (e.g. between 1025 and 65535 on
  /// most platforms). |backlog| is the maximum number of pending connections.
  /// A new thread will be created for each CreateServer call (the "dedicated
  /// server thread"). It is therefore recommended to use a different
  /// CefServerHandler instance for each CreateServer call to avoid thread
  /// safety issues in the CefServerHandler implementation. The
  /// CefServerHandler::OnServerCreated method will be called on the dedicated
  /// server thread to report success or failure. See
  /// CefServerHandler::OnServerCreated documentation for a description of
  /// server lifespan.
  ///
  /*--cef()--*/
  static void CreateServer(const CefString& address,
                           uint16_t port,
                           int backlog,
                           CefRefPtr<CefServerHandler> handler);

  ///
  /// Returns the task runner for the dedicated server thread.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefTaskRunner> GetTaskRunner() = 0;

  ///
  /// Stop the server and shut down the dedicated server thread. See
  /// CefServerHandler::OnServerCreated documentation for a description of
  /// server lifespan.
  ///
  /*--cef()--*/
  virtual void Shutdown() = 0;

  ///
  /// Returns true if the server is currently running and accepting incoming
  /// connections. See CefServerHandler::OnServerCreated documentation for a
  /// description of server lifespan. This method must be called on the
  /// dedicated server thread.
  ///
  /*--cef()--*/
  virtual bool IsRunning() = 0;

  ///
  /// Returns the server address including the port number.
  ///
  /*--cef()--*/
  virtual CefString GetAddress() = 0;

  ///
  /// Returns true if the server currently has a connection. This method must be
  /// called on the dedicated server thread.
  ///
  /*--cef()--*/
  virtual bool HasConnection() = 0;

  ///
  /// Returns true if |connection_id| represents a valid connection. This method
  /// must be called on the dedicated server thread.
  ///
  /*--cef()--*/
  virtual bool IsValidConnection(int connection_id) = 0;

  ///
  /// Send an HTTP 200 "OK" response to the connection identified by
  /// |connection_id|. |content_type| is the response content type (e.g.
  /// "text/html"), |data| is the response content, and |data_size| is the size
  /// of |data| in bytes. The contents of |data| will be copied. The connection
  /// will be closed automatically after the response is sent.
  ///
  /*--cef()--*/
  virtual void SendHttp200Response(int connection_id,
                                   const CefString& content_type,
                                   const void* data,
                                   size_t data_size) = 0;

  ///
  /// Send an HTTP 404 "Not Found" response to the connection identified by
  /// |connection_id|. The connection will be closed automatically after the
  /// response is sent.
  ///
  /*--cef()--*/
  virtual void SendHttp404Response(int connection_id) = 0;

  ///
  /// Send an HTTP 500 "Internal Server Error" response to the connection
  /// identified by |connection_id|. |error_message| is the associated error
  /// message. The connection will be closed automatically after the response is
  /// sent.
  ///
  /*--cef()--*/
  virtual void SendHttp500Response(int connection_id,
                                   const CefString& error_message) = 0;

  ///
  /// Send a custom HTTP response to the connection identified by
  /// |connection_id|. |response_code| is the HTTP response code sent in the
  /// status line (e.g. 200), |content_type| is the response content type sent
  /// as the "Content-Type" header (e.g. "text/html"), |content_length| is the
  /// expected content length, and |extra_headers| is the map of extra response
  /// headers. If |content_length| is >= 0 then the "Content-Length" header will
  /// be sent. If |content_length| is 0 then no content is expected and the
  /// connection will be closed automatically after the response is sent. If
  /// |content_length| is < 0 then no "Content-Length" header will be sent and
  /// the client will continue reading until the connection is closed. Use the
  /// SendRawData method to send the content, if applicable, and call
  /// CloseConnection after all content has been sent.
  ///
  /*--cef(optional_param=extra_headers)--*/
  virtual void SendHttpResponse(int connection_id,
                                int response_code,
                                const CefString& content_type,
                                int64_t content_length,
                                const HeaderMap& extra_headers) = 0;

  ///
  /// Send raw data directly to the connection identified by |connection_id|.
  /// |data| is the raw data and |data_size| is the size of |data| in bytes.
  /// The contents of |data| will be copied. No validation of |data| is
  /// performed internally so the client should be careful to send the amount
  /// indicated by the "Content-Length" header, if specified. See
  /// SendHttpResponse documentation for intended usage.
  ///
  /*--cef()--*/
  virtual void SendRawData(int connection_id,
                           const void* data,
                           size_t data_size) = 0;

  ///
  /// Close the connection identified by |connection_id|. See SendHttpResponse
  /// documentation for intended usage.
  ///
  /*--cef()--*/
  virtual void CloseConnection(int connection_id) = 0;

  ///
  /// Send a WebSocket message to the connection identified by |connection_id|.
  /// |data| is the response content and |data_size| is the size of |data| in
  /// bytes. The contents of |data| will be copied. See
  /// CefServerHandler::OnWebSocketRequest documentation for intended usage.
  ///
  /*--cef()--*/
  virtual void SendWebSocketMessage(int connection_id,
                                    const void* data,
                                    size_t data_size) = 0;
};

///
/// Implement this interface to handle HTTP server requests. A new thread will
/// be created for each CefServer::CreateServer call (the "dedicated server
/// thread"), and the methods of this class will be called on that thread. It is
/// therefore recommended to use a different CefServerHandler instance for each
/// CefServer::CreateServer call to avoid thread safety issues in the
/// CefServerHandler implementation.
///
/*--cef(source=client)--*/
class CefServerHandler : public virtual CefBaseRefCounted {
 public:
  ///
  /// Called when |server| is created. If the server was started successfully
  /// then CefServer::IsRunning will return true. The server will continue
  /// running until CefServer::Shutdown is called, after which time
  /// OnServerDestroyed will be called. If the server failed to start then
  /// OnServerDestroyed will be called immediately after this method returns.
  ///
  /*--cef()--*/
  virtual void OnServerCreated(CefRefPtr<CefServer> server) = 0;

  ///
  /// Called when |server| is destroyed. The server thread will be stopped after
  /// this method returns. The client should release any references to |server|
  /// when this method is called. See OnServerCreated documentation for a
  /// description of server lifespan.
  ///
  /*--cef()--*/
  virtual void OnServerDestroyed(CefRefPtr<CefServer> server) = 0;

  ///
  /// Called when a client connects to |server|. |connection_id| uniquely
  /// identifies the connection. Each call to this method will have a matching
  /// call to OnClientDisconnected.
  ///
  /*--cef()--*/
  virtual void OnClientConnected(CefRefPtr<CefServer> server,
                                 int connection_id) = 0;

  ///
  /// Called when a client disconnects from |server|. |connection_id| uniquely
  /// identifies the connection. The client should release any data associated
  /// with |connection_id| when this method is called and |connection_id| should
  /// no longer be passed to CefServer methods. Disconnects can originate from
  /// either the client or the server. For example, the server will disconnect
  /// automatically after a CefServer::SendHttpXXXResponse method is called.
  ///
  /*--cef()--*/
  virtual void OnClientDisconnected(CefRefPtr<CefServer> server,
                                    int connection_id) = 0;

  ///
  /// Called when |server| receives an HTTP request. |connection_id| uniquely
  /// identifies the connection, |client_address| is the requesting IPv4 or IPv6
  /// client address including port number, and |request| contains the request
  /// contents (URL, method, headers and optional POST data). Call CefServer
  /// methods either synchronously or asynchronusly to send a response.
  ///
  /*--cef()--*/
  virtual void OnHttpRequest(CefRefPtr<CefServer> server,
                             int connection_id,
                             const CefString& client_address,
                             CefRefPtr<CefRequest> request) = 0;

  ///
  /// Called when |server| receives a WebSocket request. |connection_id|
  /// uniquely identifies the connection, |client_address| is the requesting
  /// IPv4 or IPv6 client address including port number, and |request| contains
  /// the request contents (URL, method, headers and optional POST data).
  /// Execute |callback| either synchronously or asynchronously to accept or
  /// decline the WebSocket connection. If the request is accepted then
  /// OnWebSocketConnected will be called after the WebSocket has connected and
  /// incoming messages will be delivered to the OnWebSocketMessage callback. If
  /// the request is declined then the client will be disconnected and
  /// OnClientDisconnected will be called. Call the
  /// CefServer::SendWebSocketMessage method after receiving the
  /// OnWebSocketConnected callback to respond with WebSocket messages.
  ///
  /*--cef()--*/
  virtual void OnWebSocketRequest(CefRefPtr<CefServer> server,
                                  int connection_id,
                                  const CefString& client_address,
                                  CefRefPtr<CefRequest> request,
                                  CefRefPtr<CefCallback> callback) = 0;

  ///
  /// Called after the client has accepted the WebSocket connection for |server|
  /// and |connection_id| via the OnWebSocketRequest callback. See
  /// OnWebSocketRequest documentation for intended usage.
  ///
  /*--cef()--*/
  virtual void OnWebSocketConnected(CefRefPtr<CefServer> server,
                                    int connection_id) = 0;

  ///
  /// Called when |server| receives an WebSocket message. |connection_id|
  /// uniquely identifies the connection, |data| is the message content and
  /// |data_size| is the size of |data| in bytes. Do not keep a reference to
  /// |data| outside of this method. See OnWebSocketRequest documentation for
  /// intended usage.
  ///
  /*--cef()--*/
  virtual void OnWebSocketMessage(CefRefPtr<CefServer> server,
                                  int connection_id,
                                  const void* data,
                                  size_t data_size) = 0;
};

#endif  // CEF_INCLUDE_CEF_SERVER_H_
