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

#ifndef CEF_INCLUDE_CEF_REQUEST_H_
#define CEF_INCLUDE_CEF_REQUEST_H_
#pragma once

#include <map>
#include <vector>

#include "include/cef_base.h"

class CefPostData;
class CefPostDataElement;

///
/// Class used to represent a web request. The methods of this class may be
/// called on any thread.
///
/*--cef(source=library,no_debugct_check)--*/
class CefRequest : public virtual CefBaseRefCounted {
 public:
  typedef std::multimap<CefString, CefString> HeaderMap;
  typedef cef_referrer_policy_t ReferrerPolicy;
  typedef cef_resource_type_t ResourceType;
  typedef cef_transition_type_t TransitionType;

  ///
  /// Create a new CefRequest object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefRequest> Create();

  ///
  /// Returns true if this object is read-only.
  ///
  /*--cef()--*/
  virtual bool IsReadOnly() = 0;

  ///
  /// Get the fully qualified URL.
  ///
  /*--cef()--*/
  virtual CefString GetURL() = 0;

  ///
  /// Set the fully qualified URL.
  ///
  /*--cef()--*/
  virtual void SetURL(const CefString& url) = 0;

  ///
  /// Get the request method type. The value will default to POST if post data
  /// is provided and GET otherwise.
  ///
  /*--cef()--*/
  virtual CefString GetMethod() = 0;

  ///
  /// Set the request method type.
  ///
  /*--cef()--*/
  virtual void SetMethod(const CefString& method) = 0;

  ///
  /// Set the referrer URL and policy. If non-empty the referrer URL must be
  /// fully qualified with an HTTP or HTTPS scheme component. Any username,
  /// password or ref component will be removed.
  ///
  /*--cef(optional_param=referrer_url)--*/
  virtual void SetReferrer(const CefString& referrer_url,
                           ReferrerPolicy policy) = 0;

  ///
  /// Get the referrer URL.
  ///
  /*--cef()--*/
  virtual CefString GetReferrerURL() = 0;

  ///
  /// Get the referrer policy.
  ///
  /*--cef(default_retval=REFERRER_POLICY_DEFAULT)--*/
  virtual ReferrerPolicy GetReferrerPolicy() = 0;

  ///
  /// Get the post data.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefPostData> GetPostData() = 0;

  ///
  /// Set the post data.
  ///
  /*--cef()--*/
  virtual void SetPostData(CefRefPtr<CefPostData> postData) = 0;

  ///
  /// Get the header values. Will not include the Referer value if any.
  ///
  /*--cef()--*/
  virtual void GetHeaderMap(HeaderMap& headerMap) = 0;

  ///
  /// Set the header values. If a Referer value exists in the header map it will
  /// be removed and ignored.
  ///
  /*--cef()--*/
  virtual void SetHeaderMap(const HeaderMap& headerMap) = 0;

  ///
  /// Returns the first header value for |name| or an empty string if not found.
  /// Will not return the Referer value if any. Use GetHeaderMap instead if
  /// |name| might have multiple values.
  ///
  /*--cef()--*/
  virtual CefString GetHeaderByName(const CefString& name) = 0;

  ///
  /// Set the header |name| to |value|. If |overwrite| is true any existing
  /// values will be replaced with the new value. If |overwrite| is false any
  /// existing values will not be overwritten. The Referer value cannot be set
  /// using this method.
  ///
  /*--cef(optional_param=value)--*/
  virtual void SetHeaderByName(const CefString& name,
                               const CefString& value,
                               bool overwrite) = 0;

  ///
  /// Set all values at one time.
  ///
  /*--cef(optional_param=postData)--*/
  virtual void Set(const CefString& url,
                   const CefString& method,
                   CefRefPtr<CefPostData> postData,
                   const HeaderMap& headerMap) = 0;

  ///
  /// Get the flags used in combination with CefURLRequest. See
  /// cef_urlrequest_flags_t for supported values.
  ///
  /*--cef(default_retval=UR_FLAG_NONE)--*/
  virtual int GetFlags() = 0;

  ///
  /// Set the flags used in combination with CefURLRequest.  See
  /// cef_urlrequest_flags_t for supported values.
  ///
  /*--cef()--*/
  virtual void SetFlags(int flags) = 0;

  ///
  /// Get the URL to the first party for cookies used in combination with
  /// CefURLRequest.
  ///
  /*--cef()--*/
  virtual CefString GetFirstPartyForCookies() = 0;

  ///
  /// Set the URL to the first party for cookies used in combination with
  /// CefURLRequest.
  ///
  /*--cef(optional_param=url)--*/
  virtual void SetFirstPartyForCookies(const CefString& url) = 0;

  ///
  /// Get the resource type for this request. Only available in the browser
  /// process.
  ///
  /*--cef(default_retval=RT_SUB_RESOURCE)--*/
  virtual ResourceType GetResourceType() = 0;

  ///
  /// Get the transition type for this request. Only available in the browser
  /// process and only applies to requests that represent a main frame or
  /// sub-frame navigation.
  ///
  /*--cef(default_retval=TT_EXPLICIT)--*/
  virtual TransitionType GetTransitionType() = 0;

  ///
  /// Returns the globally unique identifier for this request or 0 if not
  /// specified. Can be used by CefResourceRequestHandler implementations in the
  /// browser process to track a single request across multiple callbacks.
  ///
  /*--cef()--*/
  virtual uint64_t GetIdentifier() = 0;
};

///
/// Class used to represent post data for a web request. The methods of this
/// class may be called on any thread.
///
/*--cef(source=library,no_debugct_check)--*/
class CefPostData : public virtual CefBaseRefCounted {
 public:
  typedef std::vector<CefRefPtr<CefPostDataElement>> ElementVector;

  ///
  /// Create a new CefPostData object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefPostData> Create();

  ///
  /// Returns true if this object is read-only.
  ///
  /*--cef()--*/
  virtual bool IsReadOnly() = 0;

  ///
  /// Returns true if the underlying POST data includes elements that are not
  /// represented by this CefPostData object (for example, multi-part file
  /// upload data). Modifying CefPostData objects with excluded elements may
  /// result in the request failing.
  ///
  /*--cef()--*/
  virtual bool HasExcludedElements() = 0;

  ///
  /// Returns the number of existing post data elements.
  ///
  /*--cef()--*/
  virtual size_t GetElementCount() = 0;

  ///
  /// Retrieve the post data elements.
  ///
  /*--cef(count_func=elements:GetElementCount)--*/
  virtual void GetElements(ElementVector& elements) = 0;

  ///
  /// Remove the specified post data element.  Returns true if the removal
  /// succeeds.
  ///
  /*--cef()--*/
  virtual bool RemoveElement(CefRefPtr<CefPostDataElement> element) = 0;

  ///
  /// Add the specified post data element.  Returns true if the add succeeds.
  ///
  /*--cef()--*/
  virtual bool AddElement(CefRefPtr<CefPostDataElement> element) = 0;

  ///
  /// Remove all existing post data elements.
  ///
  /*--cef()--*/
  virtual void RemoveElements() = 0;
};

///
/// Class used to represent a single element in the request post data. The
/// methods of this class may be called on any thread.
///
/*--cef(source=library,no_debugct_check)--*/
class CefPostDataElement : public virtual CefBaseRefCounted {
 public:
  ///
  /// Post data elements may represent either bytes or files.
  ///
  typedef cef_postdataelement_type_t Type;

  ///
  /// Create a new CefPostDataElement object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefPostDataElement> Create();

  ///
  /// Returns true if this object is read-only.
  ///
  /*--cef()--*/
  virtual bool IsReadOnly() = 0;

  ///
  /// Remove all contents from the post data element.
  ///
  /*--cef()--*/
  virtual void SetToEmpty() = 0;

  ///
  /// The post data element will represent a file.
  ///
  /*--cef()--*/
  virtual void SetToFile(const CefString& fileName) = 0;

  ///
  /// The post data element will represent bytes.  The bytes passed
  /// in will be copied.
  ///
  /*--cef()--*/
  virtual void SetToBytes(size_t size, const void* bytes) = 0;

  ///
  /// Return the type of this post data element.
  ///
  /*--cef(default_retval=PDE_TYPE_EMPTY)--*/
  virtual Type GetType() = 0;

  ///
  /// Return the file name.
  ///
  /*--cef()--*/
  virtual CefString GetFile() = 0;

  ///
  /// Return the number of bytes.
  ///
  /*--cef()--*/
  virtual size_t GetBytesCount() = 0;

  ///
  /// Read up to |size| bytes into |bytes| and return the number of bytes
  /// actually read.
  ///
  /*--cef()--*/
  virtual size_t GetBytes(size_t size, void* bytes) = 0;
};

#endif  // CEF_INCLUDE_CEF_REQUEST_H_
