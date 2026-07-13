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

#ifndef CEF_INCLUDE_INTERNAL_CEF_TYPES_COMPONENT_H_
#define CEF_INCLUDE_INTERNAL_CEF_TYPES_COMPONENT_H_
#pragma once

#include "include/cef_api_hash.h"

#ifdef __cplusplus
extern "C" {
#endif

#if CEF_API_ADDED(14600)

///
/// Component update error codes. These map to update_client::Error values
/// from components/update_client/update_client_errors.h
///
typedef enum {
  ///
  /// No error.
  ///
  CEF_COMPONENT_UPDATE_ERROR_NONE = 0,

  ///
  /// An update is already in progress for this component.
  ///
  CEF_COMPONENT_UPDATE_ERROR_UPDATE_IN_PROGRESS = 1,

  ///
  /// The update was canceled.
  ///
  CEF_COMPONENT_UPDATE_ERROR_UPDATE_CANCELED = 2,

  ///
  /// The update should be retried later.
  ///
  CEF_COMPONENT_UPDATE_ERROR_RETRY_LATER = 3,

  ///
  /// A service error occurred.
  ///
  CEF_COMPONENT_UPDATE_ERROR_SERVICE_ERROR = 4,

  ///
  /// An error occurred during the update check.
  ///
  CEF_COMPONENT_UPDATE_ERROR_UPDATE_CHECK_ERROR = 5,

  ///
  /// The component was not found.
  ///
  CEF_COMPONENT_UPDATE_ERROR_CRX_NOT_FOUND = 6,

  ///
  /// An invalid argument was provided.
  ///
  CEF_COMPONENT_UPDATE_ERROR_INVALID_ARGUMENT = 7,

  ///
  /// Bad CRX data callback.
  ///
  CEF_COMPONENT_UPDATE_ERROR_BAD_CRX_DATA_CALLBACK = 8,

} cef_component_update_error_t;

///
/// Component update priority. Maps to
/// component_updater::OnDemandUpdater::Priority.
///
typedef enum {
  ///
  /// Background priority. Update requests may be queued.
  ///
  CEF_COMPONENT_UPDATE_PRIORITY_BACKGROUND = 0,

  ///
  /// Foreground priority. Update requests are processed immediately.
  ///
  CEF_COMPONENT_UPDATE_PRIORITY_FOREGROUND = 1,

} cef_component_update_priority_t;

///
/// Component state values. These map to update_client::ComponentState values
/// from components/update_client/update_client.h
///
/// A component is considered "installed" when its state is one of:
/// CEF_COMPONENT_STATE_UPDATED, CEF_COMPONENT_STATE_UP_TO_DATE, or
/// CEF_COMPONENT_STATE_RUN.
///
typedef enum {
  ///
  /// The component has not yet been checked for updates.
  ///
  CEF_COMPONENT_STATE_NEW = 0,

  ///
  /// The component is being checked for updates now.
  ///
  CEF_COMPONENT_STATE_CHECKING = 1,

  ///
  /// An update is available and will soon be processed.
  ///
  CEF_COMPONENT_STATE_CAN_UPDATE = 2,

  ///
  /// An update is being downloaded.
  ///
  CEF_COMPONENT_STATE_DOWNLOADING = 3,

  ///
  /// An update is being decompressed.
  ///
  CEF_COMPONENT_STATE_DECOMPRESSING = 4,

  ///
  /// A patch is being applied.
  ///
  CEF_COMPONENT_STATE_PATCHING = 5,

  ///
  /// An update is being installed.
  ///
  CEF_COMPONENT_STATE_UPDATING = 6,

  ///
  /// An update was successfully applied. The component is now installed.
  ///
  CEF_COMPONENT_STATE_UPDATED = 7,

  ///
  /// The component was already up to date. The component is installed.
  ///
  CEF_COMPONENT_STATE_UP_TO_DATE = 8,

  ///
  /// The service encountered an error during the update process.
  ///
  CEF_COMPONENT_STATE_UPDATE_ERROR = 9,

  ///
  /// The component is running a server-specified action. The component is
  /// installed.
  ///
  CEF_COMPONENT_STATE_RUN = 10,

} cef_component_state_t;

#endif  // CEF_API_ADDED(14600)

#ifdef __cplusplus
}
#endif

#endif  // CEF_INCLUDE_INTERNAL_CEF_TYPES_COMPONENT_H_
