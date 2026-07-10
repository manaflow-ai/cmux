// Copyright (c) 2026 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_COMPONENT_UPDATER_H_
#define CEF_INCLUDE_CEF_COMPONENT_UPDATER_H_
#pragma once

#include <vector>

#include "include/cef_api_hash.h"
#include "include/cef_base.h"
#include "include/internal/cef_types_component.h"

#if CEF_API_ADDED(14600)

///
/// Callback interface for component update results.
///
/*--cef(source=client,added=14600)--*/
class CefComponentUpdateCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// Called when the component update operation completes.
  /// |component_id| is the ID of the component that was updated.
  /// |error| contains the result of the operation.
  ///
  /*--cef()--*/
  virtual void OnComplete(const CefString& component_id,
                          cef_component_update_error_t error) = 0;
};

///
/// Class representing a snapshot of a component's state at the time of
/// retrieval. To get updated information, retrieve a new CefComponent object
/// via CefComponentUpdater::GetComponentByID or GetComponents. The methods of
/// this class may be called on any thread.
///
/*--cef(source=library,added=14600)--*/
class CefComponent : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns the unique identifier for this component.
  ///
  /*--cef()--*/
  virtual CefString GetID() = 0;

  ///
  /// Returns the human-readable name of this component.
  /// Returns an empty string if the component is not installed.
  ///
  /*--cef()--*/
  virtual CefString GetName() = 0;

  ///
  /// Returns the version of this component as a string (e.g., "1.2.3.4").
  /// Returns an empty string if the component is not installed.
  ///
  /*--cef()--*/
  virtual CefString GetVersion() = 0;

  ///
  /// Returns the state of this component at the time this object was created.
  /// A component is considered installed when its state is one of:
  /// CEF_COMPONENT_STATE_UPDATED, CEF_COMPONENT_STATE_UP_TO_DATE, or
  /// CEF_COMPONENT_STATE_RUN.
  ///
  /*--cef(default_retval=CEF_COMPONENT_STATE_NEW)--*/
  virtual cef_component_state_t GetState() = 0;
};

///
/// This class provides access to Chromium's component updater service, allowing
/// clients to discover registered components and trigger on-demand updates. The
/// methods of this class may only be called on the browser process UI thread.
/// If the CEF context is not initialized or the component updater service is
/// not available, methods will return safe defaults (0, nullptr, or empty).
///
/*--cef(source=library,added=14600)--*/
class CefComponentUpdater : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns the global CefComponentUpdater singleton. Returns nullptr if
  /// called from the incorrect thread.
  ///
  /*--cef()--*/
  static CefRefPtr<CefComponentUpdater> GetComponentUpdater();

  ///
  /// Returns the number of registered components, or 0 if the service is not
  /// available.
  ///
  /*--cef()--*/
  virtual size_t GetComponentCount() = 0;

  ///
  /// Populates |components| with all registered components. Any existing
  /// contents will be cleared first.
  ///
  /*--cef(count_func=components:GetComponentCount)--*/
  virtual void GetComponents(
      std::vector<CefRefPtr<CefComponent>>& components) = 0;

  ///
  /// Returns the component with the specified |component_id|, or nullptr if
  /// not found or the service is not available.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefComponent> GetComponentByID(
      const CefString& component_id) = 0;

  ///
  /// Triggers an on-demand update for the component with the specified
  /// |component_id|. |priority| specifies whether the update should be
  /// processed in the background or foreground. Use
  /// CEF_COMPONENT_UPDATE_PRIORITY_FOREGROUND for user-initiated updates.
  ///
  /// |callback| will be called asynchronously on the UI thread when the
  /// update operation completes. The callback is always executed, including
  /// when the component is already up-to-date (returns
  /// CEF_COMPONENT_UPDATE_ERROR_NONE), when the requested component doesn't
  /// exist, or when the service is unavailable (returns
  /// CEF_COMPONENT_UPDATE_ERROR_SERVICE_ERROR). The callback may be nullptr
  /// if no notification is needed.
  ///
  /*--cef(optional_param=callback)--*/
  virtual void Update(const CefString& component_id,
                      cef_component_update_priority_t priority,
                      CefRefPtr<CefComponentUpdateCallback> callback) = 0;
};

#endif  // CEF_API_ADDED(14600)

#endif  // CEF_INCLUDE_CEF_COMPONENT_UPDATER_H_
