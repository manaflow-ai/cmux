// Copyright (c) 2012 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_PARSER_H_
#define CEF_INCLUDE_CEF_PARSER_H_
#pragma once

#include <vector>

#include "include/cef_base.h"
#include "include/cef_values.h"

///
/// Combines specified |base_url| and |relative_url| into |resolved_url|.
/// Returns false if one of the URLs is empty or invalid.
///
/*--cef()--*/
bool CefResolveURL(const CefString& base_url,
                   const CefString& relative_url,
                   CefString& resolved_url);

///
/// Parse the specified |url| into its component parts.
/// Returns false if the URL is empty or invalid.
///
/*--cef()--*/
bool CefParseURL(const CefString& url, CefURLParts& parts);

///
/// Creates a URL from the specified |parts|, which must contain a non-empty
/// spec or a non-empty host and path (at a minimum), but not both.
/// Returns false if |parts| isn't initialized as described.
///
/*--cef()--*/
bool CefCreateURL(const CefURLParts& parts, CefString& url);

///
/// This is a convenience function for formatting a URL in a concise and human-
/// friendly way to help users make security-related decisions (or in other
/// circumstances when people need to distinguish sites, origins, or otherwise-
/// simplified URLs from each other). Internationalized domain names (IDN) may
/// be presented in Unicode if the conversion is considered safe. The returned
/// value will (a) omit the path for standard schemes, excepting file and
/// filesystem, and (b) omit the port if it is the default for the scheme. Do
/// not use this for URLs which will be parsed or sent to other applications.
///
/*--cef(optional_param=languages)--*/
CefString CefFormatUrlForSecurityDisplay(const CefString& origin_url);

///
/// Returns the mime type for the specified file extension or an empty string if
/// unknown.
///
/*--cef()--*/
CefString CefGetMimeType(const CefString& extension);

///
/// Get the extensions associated with the given mime type. This should be
/// passed in lower case. There could be multiple extensions for a given mime
/// type, like "html,htm" for "text/html", or "txt,text,html,..." for "text/*".
/// Any existing elements in the provided vector will not be erased.
///
/*--cef()--*/
void CefGetExtensionsForMimeType(const CefString& mime_type,
                                 std::vector<CefString>& extensions);

///
/// Encodes |data| as a base64 string.
///
/*--cef()--*/
CefString CefBase64Encode(const void* data, size_t data_size);

///
/// Decodes the base64 encoded string |data|. The returned value will be NULL if
/// the decoding fails.
///
/*--cef()--*/
CefRefPtr<CefBinaryValue> CefBase64Decode(const CefString& data);

///
/// Escapes characters in |text| which are unsuitable for use as a query
/// parameter value. Everything except alphanumerics and -_.!~*'() will be
/// converted to "%XX". If |use_plus| is true spaces will change to "+". The
/// result is basically the same as encodeURIComponent in Javacript.
///
/*--cef()--*/
CefString CefURIEncode(const CefString& text, bool use_plus);

///
/// Unescapes |text| and returns the result. Unescaping consists of looking for
/// the exact pattern "%XX" where each X is a hex digit and converting to the
/// character with the numerical value of those digits (e.g. "i%20=%203%3b"
/// unescapes to "i = 3;"). If |convert_to_utf8| is true this function will
/// attempt to interpret the initial decoded result as UTF-8. If the result is
/// convertable into UTF-8 it will be returned as converted. Otherwise the
/// initial decoded result will be returned.  The |unescape_rule| parameter
/// supports further customization the decoding process.
///
/*--cef()--*/
CefString CefURIDecode(const CefString& text,
                       bool convert_to_utf8,
                       cef_uri_unescape_rule_t unescape_rule);

///
/// Parses the specified |json_string| and returns a dictionary or list
/// representation. If JSON parsing fails this method returns NULL.
///
/*--cef()--*/
CefRefPtr<CefValue> CefParseJSON(const CefString& json_string,
                                 cef_json_parser_options_t options);

///
/// Parses the specified UTF8-encoded |json| buffer of size |json_size| and
/// returns a dictionary or list representation. If JSON parsing fails this
/// method returns NULL.
///
/*--cef(capi_name=cef_parse_json_buffer)--*/
CefRefPtr<CefValue> CefParseJSON(const void* json,
                                 size_t json_size,
                                 cef_json_parser_options_t options);

///
/// Parses the specified |json_string| and returns a dictionary or list
/// representation. If JSON parsing fails this method returns NULL and populates
/// |error_msg_out| with a formatted error message.
///
/*--cef()--*/
CefRefPtr<CefValue> CefParseJSONAndReturnError(
    const CefString& json_string,
    cef_json_parser_options_t options,
    CefString& error_msg_out);

///
/// Generates a JSON string from the specified root |node| which should be a
/// dictionary or list value. Returns an empty string on failure. This method
/// requires exclusive access to |node| including any underlying data.
///
/*--cef()--*/
CefString CefWriteJSON(CefRefPtr<CefValue> node,
                       cef_json_writer_options_t options);

#endif  // CEF_INCLUDE_CEF_PARSER_H_
