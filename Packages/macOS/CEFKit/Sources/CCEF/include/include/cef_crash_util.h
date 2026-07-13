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

#ifndef CEF_INCLUDE_CEF_CRASH_UTIL_H_
#define CEF_INCLUDE_CEF_CRASH_UTIL_H_
#pragma once

///
/// Crash reporting is configured using an INI-style config file named
/// "crash_reporter.cfg". On Windows and Linux this file must be placed next to
/// the main application executable. On macOS this file must be placed in the
/// top-level app bundle Resources directory (e.g.
/// "<appname>.app/Contents/Resources"). File contents are as follows:
///
/// <pre>
///  # Comments start with a hash character and must be on their own line.
///
///  [Config]
///  ProductName=<Value of the "prod" crash key; defaults to "cef">
///  ProductVersion=<Value of the "ver" crash key; defaults to the CEF version>
///  AppName=<Windows only; App-specific folder name component for storing crash
///           information; default to "CEF">
///  ExternalHandler=<Windows only; Name of the external handler exe to use
///                   instead of re-launching the main exe; default to empty>
///  BrowserCrashForwardingEnabled=<macOS only; True if browser process crashes
///                                 should be forwarded to the system crash
///                                 reporter; default to false>
///  ServerURL=<crash server URL; default to empty>
///  RateLimitEnabled=<True if uploads should be rate limited; default to true>
///  MaxUploadsPerDay=<Max uploads per 24 hours, used if rate limit is enabled;
///                    default to 5>
///  MaxDatabaseSizeInMb=<Total crash report disk usage greater than this value
///                       will cause older reports to be deleted; default to 20>
///  MaxDatabaseAgeInDays=<Crash reports older than this value will be deleted;
///                        default to 5>
///
///  [CrashKeys]
///  my_key1=<small|medium|large>
///  my_key2=<small|medium|large>
/// </pre>
///
/// <b>Config section:</b>
///
/// If "ProductName" and/or "ProductVersion" are set then the specified values
/// will be included in the crash dump metadata. On macOS if these values are
/// set to empty then they will be retrieved from the Info.plist file using the
/// "CFBundleName" and "CFBundleShortVersionString" keys respectively.
///
/// If "AppName" is set on Windows then crash report information (metrics,
/// database and dumps) will be stored locally on disk under the
/// "C:\Users\[CurrentUser]\AppData\Local\[AppName]\User Data" folder. On other
/// platforms the cef_settings_t.root_cache_path value will be used.
///
/// If "ExternalHandler" is set on Windows then the specified exe will be
/// launched as the crashpad-handler instead of re-launching the main process
/// exe. The value can be an absolute path or a path relative to the main exe
/// directory. On Linux the cef_settings_t.browser_subprocess_path value will be
/// used. On macOS the existing subprocess app bundle will be used.
///
/// If "BrowserCrashForwardingEnabled" is set to true on macOS then browser
/// process crashes will be forwarded to the system crash reporter. This results
/// in the crash UI dialog being displayed to the user and crash reports being
/// logged under "~/Library/Logs/DiagnosticReports". Forwarding of crash reports
/// from non-browser processes and Debug builds is always disabled.
///
/// If "ServerURL" is set then crashes will be uploaded as a multi-part POST
/// request to the specified URL. Otherwise, reports will only be stored locally
/// on disk.
///
/// If "RateLimitEnabled" is set to true then crash report uploads will be rate
/// limited as follows:
///  1. If "MaxUploadsPerDay" is set to a positive value then at most the
///     specified number of crashes will be uploaded in each 24 hour period.
///  2. If crash upload fails due to a network or server error then an
///     incremental backoff delay up to a maximum of 24 hours will be applied
///     for retries.
///  3. If a backoff delay is applied and "MaxUploadsPerDay" is > 1 then the
///     "MaxUploadsPerDay" value will be reduced to 1 until the client is
///     restarted. This helps to avoid an upload flood when the network or
///     server error is resolved.
/// Rate limiting is not supported on Linux.
///
/// If "MaxDatabaseSizeInMb" is set to a positive value then crash report
/// storage on disk will be limited to that size in megabytes. For example, on
/// Windows each dump is about 600KB so a "MaxDatabaseSizeInMb" value of 20
/// equates to about 34 crash reports stored on disk. Not supported on Linux.
///
/// If "MaxDatabaseAgeInDays" is set to a positive value then crash reports
/// older than the specified age in days will be deleted. Not supported on
/// Linux.
///
/// <b>CrashKeys section:</b>
///
/// A maximum of 26 crash keys of each size can be specified for use by the
/// application. Crash key values will be truncated based on the specified size
/// (small = 64 bytes, medium = 256 bytes, large = 1024 bytes). The value of
/// crash keys can be set from any thread or process using the
/// CefSetCrashKeyValue function. These key/value pairs will be sent to the
/// crash server along with the crash dump file.
///
/*--cef()--*/
bool CefCrashReportingEnabled();

#include "include/cef_base.h"

///
/// Sets or clears a specific key-value pair from the crash metadata.
///
/*--cef(optional_param=value)--*/
void CefSetCrashKeyValue(const CefString& key, const CefString& value);

#endif  // CEF_INCLUDE_CEF_CRASH_UTIL_H_
