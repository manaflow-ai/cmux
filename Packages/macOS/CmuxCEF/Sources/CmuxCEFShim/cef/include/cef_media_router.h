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

#ifndef CEF_INCLUDE_CEF_MEDIA_ROUTER_H_
#define CEF_INCLUDE_CEF_MEDIA_ROUTER_H_
#pragma once

#include <vector>

#include "include/cef_base.h"
#include "include/cef_callback.h"
#include "include/cef_registration.h"

class CefMediaObserver;
class CefMediaRoute;
class CefMediaRouteCreateCallback;
class CefMediaSink;
class CefMediaSinkDeviceInfoCallback;
class CefMediaSource;

///
/// Supports discovery of and communication with media devices on the local
/// network via the Cast and DIAL protocols. The methods of this class may be
/// called on any browser process thread unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefMediaRouter : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns the MediaRouter object associated with the global request context.
  /// If |callback| is non-NULL it will be executed asnychronously on the UI
  /// thread after the manager's storage has been initialized. Equivalent to
  /// calling CefRequestContext::GetGlobalContext()->GetMediaRouter().
  ///
  /*--cef(optional_param=callback)--*/
  static CefRefPtr<CefMediaRouter> GetGlobalMediaRouter(
      CefRefPtr<CefCompletionCallback> callback);

  ///
  /// Add an observer for MediaRouter events. The observer will remain
  /// registered until the returned Registration object is destroyed.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefRegistration> AddObserver(
      CefRefPtr<CefMediaObserver> observer) = 0;

  ///
  /// Returns a MediaSource object for the specified media source URN. Supported
  /// URN schemes include "cast:" and "dial:", and will be already known by the
  /// client application (e.g. "cast:<appId>?clientId=<clientId>").
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefMediaSource> GetSource(const CefString& urn) = 0;

  ///
  /// Trigger an asynchronous call to CefMediaObserver::OnSinks on all
  /// registered observers.
  ///
  /*--cef()--*/
  virtual void NotifyCurrentSinks() = 0;

  ///
  /// Create a new route between |source| and |sink|. Source and sink must be
  /// valid, compatible (as reported by CefMediaSink::IsCompatibleWith), and a
  /// route between them must not already exist. |callback| will be executed
  /// on success or failure. If route creation succeeds it will also trigger an
  /// asynchronous call to CefMediaObserver::OnRoutes on all registered
  /// observers.
  ///
  /*--cef()--*/
  virtual void CreateRoute(CefRefPtr<CefMediaSource> source,
                           CefRefPtr<CefMediaSink> sink,
                           CefRefPtr<CefMediaRouteCreateCallback> callback) = 0;

  ///
  /// Trigger an asynchronous call to CefMediaObserver::OnRoutes on all
  /// registered observers.
  ///
  /*--cef()--*/
  virtual void NotifyCurrentRoutes() = 0;
};

///
/// Implemented by the client to observe MediaRouter events and registered via
/// CefMediaRouter::AddObserver. The methods of this class will be called on the
/// browser process UI thread.
///
/*--cef(source=client)--*/
class CefMediaObserver : public virtual CefBaseRefCounted {
 public:
  typedef cef_media_route_connection_state_t ConnectionState;

  ///
  /// The list of available media sinks has changed or
  /// CefMediaRouter::NotifyCurrentSinks was called.
  ///
  /*--cef()--*/
  virtual void OnSinks(const std::vector<CefRefPtr<CefMediaSink>>& sinks) = 0;

  ///
  /// The list of available media routes has changed or
  /// CefMediaRouter::NotifyCurrentRoutes was called.
  ///
  /*--cef()--*/
  virtual void OnRoutes(
      const std::vector<CefRefPtr<CefMediaRoute>>& routes) = 0;

  ///
  /// The connection state of |route| has changed.
  ///
  /*--cef()--*/
  virtual void OnRouteStateChanged(CefRefPtr<CefMediaRoute> route,
                                   ConnectionState state) = 0;

  ///
  /// A message was received over |route|. |message| is only valid for
  /// the scope of this callback and should be copied if necessary.
  ///
  /*--cef()--*/
  virtual void OnRouteMessageReceived(CefRefPtr<CefMediaRoute> route,
                                      const void* message,
                                      size_t message_size) = 0;
};

///
/// Represents the route between a media source and sink. Instances of this
/// object are created via CefMediaRouter::CreateRoute and retrieved via
/// CefMediaObserver::OnRoutes. Contains the status and metadata of a
/// routing operation. The methods of this class may be called on any browser
/// process thread unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefMediaRoute : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns the ID for this route.
  ///
  /*--cef()--*/
  virtual CefString GetId() = 0;

  ///
  /// Returns the source associated with this route.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefMediaSource> GetSource() = 0;

  ///
  /// Returns the sink associated with this route.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefMediaSink> GetSink() = 0;

  ///
  /// Send a message over this route. |message| will be copied if necessary.
  ///
  /*--cef()--*/
  virtual void SendRouteMessage(const void* message, size_t message_size) = 0;

  ///
  /// Terminate this route. Will result in an asynchronous call to
  /// CefMediaObserver::OnRoutes on all registered observers.
  ///
  /*--cef()--*/
  virtual void Terminate() = 0;
};

///
/// Callback interface for CefMediaRouter::CreateRoute. The methods of this
/// class will be called on the browser process UI thread.
///
/*--cef(source=client)--*/
class CefMediaRouteCreateCallback : public virtual CefBaseRefCounted {
 public:
  typedef cef_media_route_create_result_t RouteCreateResult;

  ///
  /// Method that will be executed when the route creation has finished.
  /// |result| will be CEF_MRCR_OK if the route creation succeeded. |error| will
  /// be a description of the error if the route creation failed. |route| is the
  /// resulting route, or empty if the route creation failed.
  ///
  /*--cef(optional_param=error,optional_param=route)--*/
  virtual void OnMediaRouteCreateFinished(RouteCreateResult result,
                                          const CefString& error,
                                          CefRefPtr<CefMediaRoute> route) = 0;
};

///
/// Represents a sink to which media can be routed. Instances of this object are
/// retrieved via CefMediaObserver::OnSinks. The methods of this class may
/// be called on any browser process thread unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefMediaSink : public virtual CefBaseRefCounted {
 public:
  typedef cef_media_sink_icon_type_t IconType;

  ///
  /// Returns the ID for this sink.
  ///
  /*--cef()--*/
  virtual CefString GetId() = 0;

  ///
  /// Returns the name of this sink.
  ///
  /*--cef()--*/
  virtual CefString GetName() = 0;

  ///
  /// Returns the icon type for this sink.
  ///
  /*--cef(default_retval=CEF_MSIT_GENERIC)--*/
  virtual IconType GetIconType() = 0;

  ///
  /// Asynchronously retrieves device info.
  ///
  /*--cef()--*/
  virtual void GetDeviceInfo(
      CefRefPtr<CefMediaSinkDeviceInfoCallback> callback) = 0;

  ///
  /// Returns true if this sink accepts content via Cast.
  ///
  /*--cef()--*/
  virtual bool IsCastSink() = 0;

  ///
  /// Returns true if this sink accepts content via DIAL.
  ///
  /*--cef()--*/
  virtual bool IsDialSink() = 0;

  ///
  /// Returns true if this sink is compatible with |source|.
  ///
  /*--cef()--*/
  virtual bool IsCompatibleWith(CefRefPtr<CefMediaSource> source) = 0;
};

///
/// Callback interface for CefMediaSink::GetDeviceInfo. The methods of this
/// class will be called on the browser process UI thread.
///
/*--cef(source=client)--*/
class CefMediaSinkDeviceInfoCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// Method that will be executed asyncronously once device information has
  /// been retrieved.
  ///
  /*--cef()--*/
  virtual void OnMediaSinkDeviceInfo(
      const CefMediaSinkDeviceInfo& device_info) = 0;
};

///
/// Represents a source from which media can be routed. Instances of this object
/// are retrieved via CefMediaRouter::GetSource. The methods of this class may
/// be called on any browser process thread unless otherwise indicated.
///
/*--cef(source=library)--*/
class CefMediaSource : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns the ID (media source URN or URL) for this source.
  ///
  /*--cef()--*/
  virtual CefString GetId() = 0;

  ///
  /// Returns true if this source outputs its content via Cast.
  ///
  /*--cef()--*/
  virtual bool IsCastSource() = 0;

  ///
  /// Returns true if this source outputs its content via DIAL.
  ///
  /*--cef()--*/
  virtual bool IsDialSource() = 0;
};

#endif  // CEF_INCLUDE_CEF_MEDIA_ROUTER_H_
