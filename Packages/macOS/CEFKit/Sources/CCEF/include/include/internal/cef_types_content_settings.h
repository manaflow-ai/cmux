// Copyright (c) 2023 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_INTERNAL_CEF_TYPES_CONTENT_SETTINGS_H_
#define CEF_INCLUDE_INTERNAL_CEF_TYPES_CONTENT_SETTINGS_H_
#pragma once

#include "include/cef_api_hash.h"

#ifdef __cplusplus
extern "C" {
#endif

///
/// Supported content setting types. Some types are platform-specific or only
/// supported with Chrome style. Should be kept in sync with Chromium's
/// ContentSettingsType type.
///
typedef enum {
  /// This setting governs whether cookies are enabled by the user in the
  /// provided context. However, it may be overridden by other settings. This
  /// enum should NOT be read directly to determine whether cookies are enabled;
  /// the client should instead rely on the CookieSettings API.
  CEF_CONTENT_SETTING_TYPE_COOKIES,

  CEF_CONTENT_SETTING_TYPE_IMAGES,
  CEF_CONTENT_SETTING_TYPE_JAVASCRIPT,

  /// This setting governs both popups and unwanted redirects like tab-unders
  /// and framebusting.
  CEF_CONTENT_SETTING_TYPE_POPUPS,

  CEF_CONTENT_SETTING_TYPE_GEOLOCATION,
  CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS,
  CEF_CONTENT_SETTING_TYPE_AUTO_SELECT_CERTIFICATE,
  CEF_CONTENT_SETTING_TYPE_MIXEDSCRIPT,
  CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC,
  CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA,
  CEF_CONTENT_SETTING_TYPE_PROTOCOL_HANDLERS,
  CEF_CONTENT_SETTING_TYPE_DEPRECATED_PPAPI_BROKER,
  CEF_CONTENT_SETTING_TYPE_AUTOMATIC_DOWNLOADS,

  /// Advanced device-specific functions on MIDI devices. MIDI-SysEx
  /// communications can be used for changing the MIDI device's persistent state
  /// such as firmware.
  CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX,

  CEF_CONTENT_SETTING_TYPE_SSL_CERT_DECISIONS,
  CEF_CONTENT_SETTING_TYPE_PROTECTED_MEDIA_IDENTIFIER,
  CEF_CONTENT_SETTING_TYPE_APP_BANNER,
  CEF_CONTENT_SETTING_TYPE_SITE_ENGAGEMENT,
#if CEF_API_ADDED(14600)
  CEF_CONTENT_SETTING_TYPE_PERSISTENT_STORAGE,
#else
  CEF_CONTENT_SETTING_TYPE_DURABLE_STORAGE,
#endif
  CEF_CONTENT_SETTING_TYPE_USB_CHOOSER_DATA,
  CEF_CONTENT_SETTING_TYPE_BLUETOOTH_GUARD,
  CEF_CONTENT_SETTING_TYPE_BACKGROUND_SYNC,
  CEF_CONTENT_SETTING_TYPE_AUTOPLAY,
  CEF_CONTENT_SETTING_TYPE_IMPORTANT_SITE_INFO,
  CEF_CONTENT_SETTING_TYPE_PERMISSION_AUTOBLOCKER_DATA,
  CEF_CONTENT_SETTING_TYPE_ADS,

  /// Website setting which stores metadata for the subresource filter to aid in
  /// decisions for whether or not to show the UI.
  CEF_CONTENT_SETTING_TYPE_ADS_DATA,

  /// MIDI stands for Musical Instrument Digital Interface. It is a standard
  /// that allows electronic musical instruments, computers, and other devices
  /// to communicate with each other.
  CEF_CONTENT_SETTING_TYPE_MIDI,

  /// This content setting type is for caching password protection service's
  /// verdicts of each origin.
  CEF_CONTENT_SETTING_TYPE_PASSWORD_PROTECTION,

  /// Website setting which stores engagement data for media related to a
  /// specific origin.
  CEF_CONTENT_SETTING_TYPE_MEDIA_ENGAGEMENT,

  /// Content setting which stores whether or not the site can play audible
  /// sound. This will not block playback but instead the user will not hear it.
  CEF_CONTENT_SETTING_TYPE_SOUND,

  /// Website setting which stores the list of client hints that the origin
  /// requested the browser to remember. The browser is expected to send all
  /// client hints in the HTTP request headers for every resource requested
  /// from that origin.
  CEF_CONTENT_SETTING_TYPE_CLIENT_HINTS,

  /// Generic Sensor API covering ambient-light-sensor, accelerometer, gyroscope
  /// and magnetometer are all mapped to a single content_settings_type.
  /// Setting for the Generic Sensor API covering ambient-light-sensor,
  /// accelerometer, gyroscope and magnetometer. These are all mapped to a
  /// single ContentSettingsType.
  CEF_CONTENT_SETTING_TYPE_SENSORS,

  /// Content setting which stores whether or not the user has granted the site
  /// permission to respond to accessibility events, which can be used to
  /// provide a custom accessibility experience. Requires explicit user consent
  /// because some users may not want sites to know they're using assistive
  /// technology. Deprecated in M131.
  CEF_CONTENT_SETTING_TYPE_DEPRECATED_ACCESSIBILITY_EVENTS,

  /// Used to store whether to allow a website to install a payment handler.
  CEF_CONTENT_SETTING_TYPE_PAYMENT_HANDLER,

  /// Content setting which stores whether to allow sites to ask for permission
  /// to access USB devices. If this is allowed specific device permissions are
  /// stored under USB_CHOOSER_DATA.
  CEF_CONTENT_SETTING_TYPE_USB_GUARD,

  /// Nothing is stored in this setting at present. Please refer to
  /// BackgroundFetchPermissionContext for details on how this permission
  /// is ascertained.
  CEF_CONTENT_SETTING_TYPE_BACKGROUND_FETCH,

  /// Website setting which stores the amount of times the user has dismissed
  /// intent picker UI without explicitly choosing an option.
  CEF_CONTENT_SETTING_TYPE_INTENT_PICKER_DISPLAY,

  /// Used to store whether to allow a website to detect user active/idle state.
  CEF_CONTENT_SETTING_TYPE_IDLE_DETECTION,

  /// Content settings for access to serial ports. The "guard" content setting
  /// stores whether to allow sites to ask for permission to access a port. The
  /// permissions granted to access particular ports are stored in the "chooser
  /// data" website setting.
  CEF_CONTENT_SETTING_TYPE_SERIAL_GUARD,
  CEF_CONTENT_SETTING_TYPE_SERIAL_CHOOSER_DATA,

  /// Nothing is stored in this setting at present. Please refer to
  /// PeriodicBackgroundSyncPermissionContext for details on how this permission
  /// is ascertained.
  /// This content setting is not registered because it does not require access
  /// to any existing providers.
  CEF_CONTENT_SETTING_TYPE_PERIODIC_BACKGROUND_SYNC,

  /// Content setting which stores whether to allow sites to ask for permission
  /// to do Bluetooth scanning.
  CEF_CONTENT_SETTING_TYPE_BLUETOOTH_SCANNING,

  /// Content settings for access to HID devices. The "guard" content setting
  /// stores whether to allow sites to ask for permission to access a device.
  /// The permissions granted to access particular devices are stored in the
  /// "chooser data" website setting.
  CEF_CONTENT_SETTING_TYPE_HID_GUARD,
  CEF_CONTENT_SETTING_TYPE_HID_CHOOSER_DATA,

  /// Wake Lock API, which has two lock types: screen and system locks.
  /// Currently, screen locks do not need any additional permission, and system
  /// locks are always denied while the right UI is worked out.
  CEF_CONTENT_SETTING_TYPE_WAKE_LOCK_SCREEN,
  CEF_CONTENT_SETTING_TYPE_WAKE_LOCK_SYSTEM,

  /// Legacy SameSite cookie behavior. This disables SameSite=Lax-by-default,
  /// SameSite=None requires Secure, and Schemeful Same-Site, forcing the
  /// legacy behavior wherein 1) cookies that don't specify SameSite are treated
  /// as SameSite=None, 2) SameSite=None cookies are not required to be Secure,
  /// and 3) schemeful same-site is not active.
  ///
  /// This will also be used to revert to legacy behavior when future changes
  /// in cookie handling are introduced.
  CEF_CONTENT_SETTING_TYPE_LEGACY_COOKIE_ACCESS,

  /// Content settings which stores whether to allow sites to ask for permission
  /// to save changes to an original file selected by the user through the
  /// File System Access API.
  CEF_CONTENT_SETTING_TYPE_FILE_SYSTEM_WRITE_GUARD,

  /// Used to store whether to allow a website to exchange data with NFC
  /// devices.
  CEF_CONTENT_SETTING_TYPE_NFC,

  /// Website setting to store permissions granted to access particular
  /// Bluetooth devices.
  CEF_CONTENT_SETTING_TYPE_BLUETOOTH_CHOOSER_DATA,

  /// Full access to the system clipboard (sanitized read without user gesture,
  /// and unsanitized read and write with user gesture).
  CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE,

  /// This is special-cased in the permissions layer to always allow, and as
  /// such doesn't have associated prefs data.
  CEF_CONTENT_SETTING_TYPE_CLIPBOARD_SANITIZED_WRITE,

  /// This content setting type is for caching safe browsing real time url
  /// check's verdicts of each origin.
  CEF_CONTENT_SETTING_TYPE_SAFE_BROWSING_URL_CHECK_DATA,

  /// Used to store whether a site is allowed to request AR or VR sessions with
  /// the WebXr Device API.
  CEF_CONTENT_SETTING_TYPE_VR,
  CEF_CONTENT_SETTING_TYPE_AR,

  /// Content setting which stores whether to allow site to open and read files
  /// and directories selected through the File System Access API.
  CEF_CONTENT_SETTING_TYPE_FILE_SYSTEM_READ_GUARD,

  /// Access to first party storage in a third-party context. Exceptions are
  /// scoped to the combination of requesting/top-level origin, and are managed
  /// through the Storage Access API. For the time being, this content setting
  /// exists in parallel to third-party cookie rules stored in COOKIES.
  CEF_CONTENT_SETTING_TYPE_STORAGE_ACCESS,

  /// Content setting which stores whether to allow a site to control camera
  /// movements. It does not give access to camera.
  CEF_CONTENT_SETTING_TYPE_CAMERA_PAN_TILT_ZOOM,

  /// Content setting for Screen Enumeration and Screen Detail functionality.
  /// Permits access to detailed multi-screen information, like size and
  /// position. Permits placing fullscreen and windowed content on specific
  /// screens. See also: https://w3c.github.io/window-placement
  CEF_CONTENT_SETTING_TYPE_WINDOW_MANAGEMENT,

/// Stores whether to allow insecure websites to make private network
/// requests.
/// See also: https://wicg.github.io/cors-rfc1918
/// Set through enterprise policies only.
#if CEF_API_ADDED(13800)
  CEF_CONTENT_SETTING_TYPE_INSECURE_PRIVATE_NETWORK_DEPRECATED,
#else
  CEF_CONTENT_SETTING_TYPE_INSECURE_PRIVATE_NETWORK,
#endif

  /// Content setting which stores whether or not a site can access low-level
  /// locally installed font data using the Local Fonts Access API.
  CEF_CONTENT_SETTING_TYPE_LOCAL_FONTS,

  /// Stores per-origin state for permission auto-revocation (for all permission
  /// types).
  CEF_CONTENT_SETTING_TYPE_PERMISSION_AUTOREVOCATION_DATA,

  /// Stores per-origin state of the most recently selected directory for the
  /// use by the File System Access API.
  CEF_CONTENT_SETTING_TYPE_FILE_SYSTEM_LAST_PICKED_DIRECTORY,

  /// Controls access to the getDisplayMedia API.
  CEF_CONTENT_SETTING_TYPE_DISPLAY_CAPTURE,

  /// Website setting to store permissions metadata granted to paths on the
  /// local file system via the File System Access API.
  /// |FILE_SYSTEM_WRITE_GUARD| is the corresponding "guard" setting. The stored
  /// data represents valid permission only if
  /// |FILE_SYSTEM_ACCESS_EXTENDED_PERMISSION| is enabled via user opt-in.
  /// Otherwise, they represent "recently granted but revoked permission", which
  /// are used to restore the permission.
  CEF_CONTENT_SETTING_TYPE_FILE_SYSTEM_ACCESS_CHOOSER_DATA,

  /// Stores a grant that allows a relying party to send a request for identity
  /// information to specified identity providers, potentially through any
  /// anti-tracking measures that would otherwise prevent it. This setting is
  /// associated with the relying party's origin.
  CEF_CONTENT_SETTING_TYPE_FEDERATED_IDENTITY_SHARING,

  /// Whether to use the v8 optimized JIT for running JavaScript on the page.
  CEF_CONTENT_SETTING_TYPE_JAVASCRIPT_JIT,

  /// Content setting which stores user decisions to allow loading a site over
  /// HTTP. Entries are added by hostname when a user bypasses the HTTPS-First
  /// Mode interstitial warning when a site does not support HTTPS. Allowed
  /// hosts are exact hostname matches -- subdomains of a host on the allowlist
  /// must be separately allowlisted.
  CEF_CONTENT_SETTING_TYPE_HTTP_ALLOWED,

  /// Stores metadata related to form fill, such as e.g. whether user data was
  /// autofilled on a specific website.
  CEF_CONTENT_SETTING_TYPE_FORMFILL_METADATA,

  /// Setting to indicate that there is an active federated sign-in session
  /// between a specified relying party and a specified identity provider for
  /// a specified account. When this is present it allows access to session
  /// management capabilities between the sites. This setting is associated
  /// with the relying party's origin.
  // Obsolete on Nov 2023.
  CEF_CONTENT_SETTING_TYPE_DEPRECATED_FEDERATED_IDENTITY_ACTIVE_SESSION,

  /// Setting to indicate whether Chrome should automatically apply darkening to
  /// web content.
  CEF_CONTENT_SETTING_TYPE_AUTO_DARK_WEB_CONTENT,

  /// Setting to indicate whether Chrome should request the desktop view of a
  /// site instead of the mobile one.
  CEF_CONTENT_SETTING_TYPE_REQUEST_DESKTOP_SITE,

  /// Setting to indicate whether browser should allow signing into a website
  /// via the browser FedCM API.
  CEF_CONTENT_SETTING_TYPE_FEDERATED_IDENTITY_API,

  /// Stores notification interactions per origin for the past 90 days.
  /// Interactions per origin are pre-aggregated over seven-day windows: A
  /// notification interaction or display is assigned to the last Monday
  /// midnight in local time.
  CEF_CONTENT_SETTING_TYPE_NOTIFICATION_INTERACTIONS,

  /// Website setting which stores the last reduced accept language negotiated
  /// for a given origin, to be used on future visits to the origin.
  CEF_CONTENT_SETTING_TYPE_REDUCED_ACCEPT_LANGUAGE,

  /// Website setting which is used for NotificationPermissionReviewService to
  /// store origin blocklist from review notification permissions feature.
  CEF_CONTENT_SETTING_TYPE_NOTIFICATION_PERMISSION_REVIEW,

#if CEF_API_ADDED(14000)
  CEF_CONTENT_SETTING_TYPE_PRIVATE_NETWORK_GUARD_DEPRECATED,
  CEF_CONTENT_SETTING_TYPE_PRIVATE_NETWORK_CHOOSER_DATA_DEPRECATED,
#else
  /// Website setting to store permissions granted to access particular devices
  /// in private network.
  CEF_CONTENT_SETTING_TYPE_PRIVATE_NETWORK_GUARD,
  CEF_CONTENT_SETTING_TYPE_PRIVATE_NETWORK_CHOOSER_DATA,
#endif

  /// Website setting which stores whether the browser has observed the user
  /// signing into an identity-provider based on observing the IdP-SignIn-Status
  /// HTTP header.
  CEF_CONTENT_SETTING_TYPE_FEDERATED_IDENTITY_IDENTITY_PROVIDER_SIGNIN_STATUS,

  /// Website setting which is used for RevokedPermissionsService to
  /// store revoked permissions of unused sites from unused site permissions
  /// feature.
  CEF_CONTENT_SETTING_TYPE_REVOKED_UNUSED_SITE_PERMISSIONS,

  /// Similar to STORAGE_ACCESS, but applicable at the page-level rather than
  /// being specific to a frame.
  CEF_CONTENT_SETTING_TYPE_TOP_LEVEL_STORAGE_ACCESS,

  /// Setting to indicate whether user has opted in to allowing auto re-authn
  /// via the FedCM API.
  CEF_CONTENT_SETTING_TYPE_FEDERATED_IDENTITY_AUTO_REAUTHN_PERMISSION,

  /// Website setting which stores whether the user has explicitly registered
  /// a website as an identity-provider.
  CEF_CONTENT_SETTING_TYPE_FEDERATED_IDENTITY_IDENTITY_PROVIDER_REGISTRATION,

  /// Content setting which is used to indicate whether anti-abuse functionality
  /// should be enabled.
  CEF_CONTENT_SETTING_TYPE_ANTI_ABUSE,

#if CEF_API_ADDED(14600)
  CEF_CONTENT_SETTING_TYPE_THIRD_PARTY_STORAGE_PARTITIONING_DEPRECATED,
#else
  /// Content setting used to indicate whether third-party storage partitioning
  /// should be enabled.
  CEF_CONTENT_SETTING_TYPE_THIRD_PARTY_STORAGE_PARTITIONING,
#endif

  /// Used to indicate whether HTTPS-First Mode is enabled on the hostname.
  CEF_CONTENT_SETTING_TYPE_HTTPS_ENFORCED,

  /// Setting for enabling the `getAllScreensMedia` API. Spec link:
  /// https://github.com/screen-share/capture-all-screens
  CEF_CONTENT_SETTING_TYPE_ALL_SCREEN_CAPTURE,

  /// Stores per origin metadata for cookie controls.
  CEF_CONTENT_SETTING_TYPE_COOKIE_CONTROLS_METADATA,

  /// Content Setting for temporary 3PC accesses granted by user behavior
  /// heuristics.
  CEF_CONTENT_SETTING_TYPE_TPCD_HEURISTICS_GRANTS,

  /// Content Setting for 3PC accesses granted by metadata delivered via the
  /// component updater service. This type will only be used when
  /// `net::features::kTpcdMetadataGrants` is enabled.
  CEF_CONTENT_SETTING_TYPE_TPCD_METADATA_GRANTS,

#if CEF_API_ADDED(14400)
  CEF_CONTENT_SETTING_TYPE_TPCD_TRIAL_DEPRECATED,
#else
  /// Content Setting for 3PC accesses granted via 3PC deprecation trial.
  CEF_CONTENT_SETTING_TYPE_TPCD_TRIAL,
#endif

#if CEF_API_ADDED(14300)
  CEF_CONTENT_SETTING_TYPE_TOP_LEVEL_TPCD_TRIAL_DEPRECATED,
#else
  /// Content Setting for 3PC accesses granted via top-level 3PC deprecation
  /// trial. Similar to TPCD_TRIAL, but applicable at the page-level for the
  /// lifetime of the page that served the token, rather than being specific to
  /// a requesting-origin/top-level-site combination and persistent.
  CEF_CONTENT_SETTING_TYPE_TOP_LEVEL_TPCD_TRIAL,
#endif

#if CEF_API_ADDED(14300)
  CEF_CONTENT_SETTING_TYPE_TOP_LEVEL_TPCD_ORIGIN_TRIAL_DEPRECATED,
#elif CEF_API_ADDED(13601)
  /// Content Setting for a first-party origin trial that allows websites to
  /// enable third-party cookie deprecation.
  /// ALLOW (default): no effect (e.g. third-party cookies allowed, if not
  ///                  blocked otherwise).
  /// BLOCK: third-party cookies blocked, but 3PCD mitigations enabled.
  CEF_CONTENT_SETTING_TYPE_TOP_LEVEL_TPCD_ORIGIN_TRIAL,
#else
  CEF_CONTENT_SETTING_TOP_LEVEL_TPCD_ORIGIN_TRIAL,
#endif

  /// Content setting used to indicate whether entering picture-in-picture
  /// automatically should be enabled.
  CEF_CONTENT_SETTING_TYPE_AUTO_PICTURE_IN_PICTURE,

  /// Whether user has opted into keeping file/directory permissions persistent
  /// between visits for a given origin. When enabled, permission metadata
  /// stored under |FILE_SYSTEM_ACCESS_CHOOSER_DATA| can auto-grant incoming
  /// permission request.
  CEF_CONTENT_SETTING_TYPE_FILE_SYSTEM_ACCESS_EXTENDED_PERMISSION,

  /// Whether the FSA Persistent Permissions restore prompt is eligible to be
  /// shown to the user, for a given origin.
  CEF_CONTENT_SETTING_TYPE_FILE_SYSTEM_ACCESS_RESTORE_PERMISSION,

  /// Whether an application capturing another tab, may scroll and zoom
  /// the captured tab.
  CEF_CONTENT_SETTING_TYPE_CAPTURED_SURFACE_CONTROL,

  /// Content setting for access to smart card readers.
  /// The "guard" content setting stores whether to allow sites to access the
  /// Smart Card API.
  CEF_CONTENT_SETTING_TYPE_SMART_CARD_GUARD,
  CEF_CONTENT_SETTING_TYPE_SMART_CARD_DATA,

  /// Content settings for access to printers for the Web Printing API.
  CEF_CONTENT_SETTING_TYPE_WEB_PRINTING,

  /// Content setting used to indicate whether entering HTML Fullscreen
  /// automatically (i.e. without transient activation) should be enabled.
  CEF_CONTENT_SETTING_TYPE_AUTOMATIC_FULLSCREEN,

  /// Content settings used to indicate that a web app is allowed to prompt the
  /// user for the installation of sub apps.
  CEF_CONTENT_SETTING_TYPE_SUB_APP_INSTALLATION_PROMPTS,

  /// Whether an application can enumerate audio output device.
  CEF_CONTENT_SETTING_TYPE_SPEAKER_SELECTION,

  /// Content settings for access to the Direct Sockets API.
  CEF_CONTENT_SETTING_TYPE_DIRECT_SOCKETS,

  /// Keyboard Lock API allows a site to capture keyboard inputs that would
  /// otherwise be handled by the OS or the browser.
  CEF_CONTENT_SETTING_TYPE_KEYBOARD_LOCK,

  /// Pointer Lock API allows a site to hide the cursor and have exclusive
  /// access to mouse inputs.
  CEF_CONTENT_SETTING_TYPE_POINTER_LOCK,

  /// Website setting which is used for RevokedPermissionsService to store
  /// auto-revoked notification permissions from abusive sites.
  CEF_CONTENT_SETTING_TYPE_REVOKED_ABUSIVE_NOTIFICATION_PERMISSIONS,

#if CEF_API_ADDED(14600)
  CEF_CONTENT_SETTING_TYPE_TRACKING_PROTECTION_DEPRECATED,
#else
  /// Content setting that controls tracking protection status per site.
  /// BLOCK: Protections enabled. This is the default state.
  /// ALLOW: Protections disabled.
  CEF_CONTENT_SETTING_TYPE_TRACKING_PROTECTION,
#endif

  /// With this permission, when the application calls `getDisplayMedia()`, a
  /// system audio track can be returned without showing the display media
  /// selection picker. The application can explicitly specify
  /// `systemAudio: 'exclude'` or `video: true` to still show the display media
  /// selection picker if needed. Please note that the setting only works for
  /// WebUI.
  CEF_CONTENT_SETTING_TYPE_DISPLAY_MEDIA_SYSTEM_AUDIO,

  /// Whether to use the higher-tier v8 optimizers for running JavaScript on the
  /// page.
  CEF_CONTENT_SETTING_TYPE_JAVASCRIPT_OPTIMIZER,

  /// Content Setting for the Storage Access Headers persistent origin trial
  /// that allows origins to opt into the storage access header behavior. Should
  /// be scoped to `REQUESTING_ORIGIN_AND_TOP_SCHEMEFUL_SITE_SCOPE` in order to
  /// correspond to the design of persistent origin trials. See also:
  /// https://github.com/cfredric/storage-access-headers
  /// ALLOW: storage access request headers will be attached to cross-site
  ///        requests, and url requests will look for response headers from
  ///        origins to retry a request or load with storage access.
  /// BLOCK (default): no effect.
  CEF_CONTENT_SETTING_TYPE_STORAGE_ACCESS_HEADER_ORIGIN_TRIAL,

  /// Whether or not sites can request Hand Tracking data within WebXR Sessions.
  CEF_CONTENT_SETTING_TYPE_HAND_TRACKING,

  /// Website setting to indicate whether user has opted in to allow web apps to
  /// install other web apps.
  CEF_CONTENT_SETTING_TYPE_WEB_APP_INSTALLATION,

  /// Content settings for private network access in the context of the
  /// Direct Sockets API.
  CEF_CONTENT_SETTING_TYPE_DIRECT_SOCKETS_PRIVATE_NETWORK_ACCESS,

  /// Content settings for legacy cookie scope.
  /// Checks whether cookies scope is handled according to origin-bound cookies
  /// or legacy behavior.
  CEF_CONTENT_SETTING_TYPE_LEGACY_COOKIE_SCOPE,

#if CEF_API_ADDED(13400)
  /// Website setting to indicate whether the user has allowlisted suspicious
  /// notifications for the origin.
  CEF_CONTENT_SETTING_TYPE_ARE_SUSPICIOUS_NOTIFICATIONS_ALLOWLISTED_BY_USER,

  /// Content settings for access to the Controlled Frame API.
  CEF_CONTENT_SETTING_TYPE_CONTROLLED_FRAME,
#endif

#if CEF_API_ADDED(13500)
  /// Website setting which is used for RevokedPermissionsService to
  /// store revoked notification permissions of disruptive sites.
  CEF_CONTENT_SETTING_TYPE_REVOKED_DISRUPTIVE_NOTIFICATION_PERMISSIONS,
#endif

#if CEF_API_ADDED(13600)
  /// Content setting for whether the site is allowed to make local network
  /// requests.
  CEF_CONTENT_SETTING_TYPE_LOCAL_NETWORK_ACCESS,
#endif

#if CEF_API_ADDED(13800)
  /// Stores information on-device language packs for which a site has
  /// installed using the Web Speech API.
  CEF_CONTENT_SETTING_TYPE_ON_DEVICE_SPEECH_RECOGNITION_LANGUAGES_DOWNLOADED,

  /// Stores which Translator API language packs the site has initialized.
  CEF_CONTENT_SETTING_TYPE_INITIALIZED_TRANSLATIONS,

  /// Stores a list of notification ids where content detection found the
  /// notification to be suspicious and a warning has already been shown for the
  /// site. Used for recovering notification contents from the database if the
  /// user decides they would like to see all of these notifications.
  CEF_CONTENT_SETTING_TYPE_SUSPICIOUS_NOTIFICATION_IDS,
#endif

#if CEF_API_ADDED(14000)
  /// To support approximate geolocation, the permission is migrating to use
  /// permissions with options, which won't be stored as ContentSettings. Upon
  /// launch of the feature, GEOLOCATION and GEOLOCATION_WITH_OPTIONS should be
  /// merged.
  CEF_CONTENT_SETTING_TYPE_GEOLOCATION_WITH_OPTIONS,

  /// Setting for enabling the Device Attributes API. Spec link:
  /// https://wicg.github.io/WebApiDevice/device_attributes/
  CEF_CONTENT_SETTING_TYPE_DEVICE_ATTRIBUTES,
#endif

#if CEF_API_ADDED(14200)
  /// Stores per-origin state for permission heuristics. Currently used for
  /// auto-granting geolocation element permission request after repeated
  /// temporary grants.
  CEF_CONTENT_SETTING_TYPE_PERMISSION_ACTIONS_HISTORY,

  /// Website setting to indicate whether the user has selected "show original"
  /// when suspicious warning is shown. If the user has selected this, the
  /// notification permission will not be revoked based on suspicious verdict.
  CEF_CONTENT_SETTING_TYPE_SUSPICIOUS_NOTIFICATION_SHOW_ORIGINAL,
#endif

#if CEF_API_ADDED(14500)
  /// Content setting for whether the site is allowed to make local network
  /// requests. Split from LOCAL_NETWORK_ACCESS.
  CEF_CONTENT_SETTING_TYPE_LOCAL_NETWORK,

  /// Content setting for whether the site is allowed to make loopback network
  /// requests. Split from LOCAL_NETWORK_ACCESS.
  CEF_CONTENT_SETTING_TYPE_LOOPBACK_NETWORK,
#endif

  CEF_CONTENT_SETTING_TYPE_NUM_VALUES,
} cef_content_setting_types_t;

///
/// Supported content setting values. Should be kept in sync with Chromium's
/// ContentSetting type.
///
typedef enum {
  CEF_CONTENT_SETTING_VALUE_DEFAULT,
  CEF_CONTENT_SETTING_VALUE_ALLOW,
  CEF_CONTENT_SETTING_VALUE_BLOCK,
  CEF_CONTENT_SETTING_VALUE_ASK,
  CEF_CONTENT_SETTING_VALUE_SESSION_ONLY,
#if CEF_API_ADDED(14000)
  CEF_CONTENT_SETTING_VALUE_DETECT_IMPORTANT_CONTENT_DEPRECATED,
#else
  CEF_CONTENT_SETTING_VALUE_DETECT_IMPORTANT_CONTENT,
#endif

  CEF_CONTENT_SETTING_VALUE_NUM_VALUES,
} cef_content_setting_values_t;

#ifdef __cplusplus
}
#endif

#endif  // CEF_INCLUDE_INTERNAL_CEF_TYPES_CONTENT_SETTINGS_H_
