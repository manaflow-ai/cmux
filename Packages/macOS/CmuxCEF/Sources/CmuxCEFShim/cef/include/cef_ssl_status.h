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

#ifndef CEF_INCLUDE_CEF_SSL_STATUS_H_
#define CEF_INCLUDE_CEF_SSL_STATUS_H_
#pragma once

#include "include/cef_base.h"
#include "include/cef_values.h"
#include "include/cef_x509_certificate.h"

///
/// Class representing the SSL information for a navigation entry.
///
/*--cef(source=library)--*/
class CefSSLStatus : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns true if the status is related to a secure SSL/TLS connection.
  ///
  /*--cef()--*/
  virtual bool IsSecureConnection() = 0;

  ///
  /// Returns a bitmask containing any and all problems verifying the server
  /// certificate.
  ///
  /*--cef(default_retval=CERT_STATUS_NONE)--*/
  virtual cef_cert_status_t GetCertStatus() = 0;

  ///
  /// Returns the SSL version used for the SSL connection.
  ///
  /*--cef(default_retval=SSL_CONNECTION_VERSION_UNKNOWN)--*/
  virtual cef_ssl_version_t GetSSLVersion() = 0;

  ///
  /// Returns a bitmask containing the page security content status.
  ///
  /*--cef(default_retval=SSL_CONTENT_NORMAL_CONTENT)--*/
  virtual cef_ssl_content_status_t GetContentStatus() = 0;

  ///
  /// Returns the X.509 certificate.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefX509Certificate> GetX509Certificate() = 0;
};

#endif  // CEF_INCLUDE_CEF_SSL_STATUS_H_
