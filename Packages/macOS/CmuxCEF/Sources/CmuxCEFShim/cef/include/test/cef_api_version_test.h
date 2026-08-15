// Copyright (c) 2024 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_TEST_CEF_API_VERSION_TEST_H_
#define CEF_INCLUDE_TEST_CEF_API_VERSION_TEST_H_
#pragma once

#if !defined(BUILDING_CEF_SHARED) && !defined(WRAPPING_CEF_SHARED) && \
    !defined(UNIT_TEST)
#error This file can be included for unit tests only
#endif

#include <vector>

#include "include/cef_api_hash.h"
#include "include/cef_base.h"

// NOTE: This test implements an example of API version changes over time.
// It is basically the same as the RefPtr/OwnPtr/RawPtr portion of
// CefTranslatorTest but with API version changes applied.
// - Legacy API has no version suffix on class/method names.
// - Changed to API v1 in CEF version 13301 (added 'V1' suffix).
// - Changed to API v2 in CEF version 13302 (changed to 'V2' suffix).

class CefApiVersionTestRefPtrClient;
#if CEF_API_REMOVED(13302)
class CefApiVersionTestRefPtrClientChild;
#endif
#if CEF_API_ADDED(13302)
class CefApiVersionTestRefPtrClientChildV2;
#endif
class CefApiVersionTestRefPtrLibrary;
class CefApiVersionTestRefPtrLibraryChild;
class CefApiVersionTestScopedClient;
#if CEF_API_REMOVED(13302)
class CefApiVersionTestScopedClientChild;
#endif
#if CEF_API_ADDED(13302)
class CefApiVersionTestScopedClientChildV2;
#endif
class CefApiVersionTestScopedLibrary;
class CefApiVersionTestScopedLibraryChild;

///
/// Class for testing versioned object transfer.
///
/*--cef(source=library)--*/
class CefApiVersionTest : public CefBaseRefCounted {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefApiVersionTest> Create();

  // LIBRARY-SIDE REFPTR VALUES

  ///
  /// Return an new library-side object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefApiVersionTestRefPtrLibrary> GetRefPtrLibrary(
      int val) = 0;

  ///
  /// Set an object. Returns the value from
  /// CefApiVersionTestRefPtrLibrary::GetValue().
  /// This tests input and execution of a library-side object type.
  ///
  /*--cef()--*/
  virtual int SetRefPtrLibrary(
      CefRefPtr<CefApiVersionTestRefPtrLibrary> val) = 0;

  ///
  /// Set an object. Returns the object passed in. This tests input and output
  /// of a library-side object type.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefApiVersionTestRefPtrLibrary> SetRefPtrLibraryAndReturn(
      CefRefPtr<CefApiVersionTestRefPtrLibrary> val) = 0;

  ///
  /// Set a child object. Returns the value from
  /// CefApiVersionTestRefPtrLibrary::GetValue(). This tests input of a library-
  /// side child object type and execution as the parent type.
  ///
  /*--cef()--*/
  virtual int SetChildRefPtrLibrary(
      CefRefPtr<CefApiVersionTestRefPtrLibraryChild> val) = 0;

  ///
  /// Set a child object. Returns the object as the parent type. This tests
  /// input of a library-side child object type and return as the parent type.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefApiVersionTestRefPtrLibrary>
  SetChildRefPtrLibraryAndReturnParent(
      CefRefPtr<CefApiVersionTestRefPtrLibraryChild> val) = 0;

  // LIBRARY-SIDE REFPTR LIST VALUES

  // Test both with and without a typedef.
  typedef std::vector<CefRefPtr<CefApiVersionTestRefPtrLibrary>>
      RefPtrLibraryList;

  ///
  /// Set an object list vlaue.
  ///
  /*--cef()--*/
  virtual bool SetRefPtrLibraryList(
      const std::vector<CefRefPtr<CefApiVersionTestRefPtrLibrary>>& val,
      int val1,
      int val2) = 0;

  ///
  /// Return an object list value by out-param.
  ///
  /*--cef(count_func=val:GetRefPtrLibraryListSize)--*/
  virtual bool GetRefPtrLibraryListByRef(RefPtrLibraryList& val,
                                         int val1,
                                         int val2) = 0;

  ///
  /// Return the number of object that will be output above.
  ///
  /*--cef()--*/
  virtual size_t GetRefPtrLibraryListSize() = 0;

  // CLIENT-SIDE REFPTR VALUES

  ///
  /// Set an object. Returns the value from
  /// CefApiVersionTestRefPtrClient::GetValue().
  /// This tests input and execution of a client-side object type.
  ///
  /*--cef()--*/
  virtual int SetRefPtrClient(CefRefPtr<CefApiVersionTestRefPtrClient> val) = 0;

  ///
  /// Set an object. Returns the handler passed in. This tests input and output
  /// of a client-side object type.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefApiVersionTestRefPtrClient> SetRefPtrClientAndReturn(
      CefRefPtr<CefApiVersionTestRefPtrClient> val) = 0;

#if CEF_API_REMOVED(13302)
  ///
  /// Set a child object. Returns the value from
  /// CefApiVersionTestRefPtrClient::GetValue(). This tests input of a client-
  /// side child object type and execution as the parent type.
  ///
  /*--cef(removed=13302)--*/
  virtual int SetChildRefPtrClient(
      CefRefPtr<CefApiVersionTestRefPtrClientChild> val) = 0;

  ///
  /// Set a child object. Returns the object as the parent type. This tests
  /// input of a client-side child object type and return as the parent type.
  ///
  /*--cef(removed=13302)--*/
  virtual CefRefPtr<CefApiVersionTestRefPtrClient>
  SetChildRefPtrClientAndReturnParent(
      CefRefPtr<CefApiVersionTestRefPtrClientChild> val) = 0;
#endif  // CEF_API_REMOVED(13302)

#if CEF_API_ADDED(13302)
  ///
  /// Set a child object. Returns the value from
  /// CefApiVersionTestRefPtrClient::GetValue(). This tests input of a client-
  /// side child object type and execution as the parent type.
  ///
  /*--cef(added=13302,capi_name=set_child_ref_ptr_client_v2)--*/
  virtual int SetChildRefPtrClient(
      CefRefPtr<CefApiVersionTestRefPtrClientChildV2> val) = 0;

  ///
  /// Set a child object. Returns the object as the parent type. This tests
  /// input of a client-side child object type and return as the parent type.
  ///
  /*--cef(added=13302,
          capi_name=set_child_ref_ptr_client_and_return_parent_v2)--*/
  virtual CefRefPtr<CefApiVersionTestRefPtrClient>
  SetChildRefPtrClientAndReturnParent(
      CefRefPtr<CefApiVersionTestRefPtrClientChildV2> val) = 0;
#endif  // CEF_API_ADDED(13302)

  // CLIENT-SIDE REFPTR LIST VALUES

  // Test both with and without a typedef.
  typedef std::vector<CefRefPtr<CefApiVersionTestRefPtrClient>>
      RefPtrClientList;

  ///
  /// Set an object list vlaue.
  ///
  /*--cef()--*/
  virtual bool SetRefPtrClientList(
      const std::vector<CefRefPtr<CefApiVersionTestRefPtrClient>>& val,
      int val1,
      int val2) = 0;

  ///
  /// Return an object list value by out-param.
  ///
  /*--cef(count_func=val:GetRefPtrLibraryListSize)--*/
  virtual bool GetRefPtrClientListByRef(
      RefPtrClientList& val,
      CefRefPtr<CefApiVersionTestRefPtrClient> val1,
      CefRefPtr<CefApiVersionTestRefPtrClient> val2) = 0;

  ///
  /// Return the number of object that will be output above.
  ///
  /*--cef()--*/
  virtual size_t GetRefPtrClientListSize() = 0;

  // LIBRARY-SIDE OWNPTR VALUES

  ///
  /// Return an new library-side object.
  ///
  /*--cef()--*/
  virtual CefOwnPtr<CefApiVersionTestScopedLibrary> GetOwnPtrLibrary(
      int val) = 0;

  ///
  /// Set an object. Returns the value from
  /// CefApiVersionTestScopedLibrary::GetValue().
  /// This tests input and execution of a library-side object type.
  ///
  /*--cef()--*/
  virtual int SetOwnPtrLibrary(
      CefOwnPtr<CefApiVersionTestScopedLibrary> val) = 0;

  ///
  /// Set an object. Returns the object passed in. This tests input and output
  /// of a library-side object type.
  ///
  /*--cef()--*/
  virtual CefOwnPtr<CefApiVersionTestScopedLibrary> SetOwnPtrLibraryAndReturn(
      CefOwnPtr<CefApiVersionTestScopedLibrary> val) = 0;

  ///
  /// Set a child object. Returns the value from
  /// CefApiVersionTestScopedLibrary::GetValue(). This tests input of a library-
  /// side child object type and execution as the parent type.
  ///
  /*--cef()--*/
  virtual int SetChildOwnPtrLibrary(
      CefOwnPtr<CefApiVersionTestScopedLibraryChild> val) = 0;

  ///
  /// Set a child object. Returns the object as the parent type. This tests
  /// input of a library-side child object type and return as the parent type.
  ///
  /*--cef()--*/
  virtual CefOwnPtr<CefApiVersionTestScopedLibrary>
  SetChildOwnPtrLibraryAndReturnParent(
      CefOwnPtr<CefApiVersionTestScopedLibraryChild> val) = 0;

  // CLIENT-SIDE OWNPTR VALUES

  ///
  /// Set an object. Returns the value from
  /// CefApiVersionTestScopedClient::GetValue().
  /// This tests input and execution of a client-side object type.
  ///
  /*--cef()--*/
  virtual int SetOwnPtrClient(CefOwnPtr<CefApiVersionTestScopedClient> val) = 0;

  ///
  /// Set an object. Returns the handler passed in. This tests input and output
  /// of a client-side object type.
  ///
  /*--cef()--*/
  virtual CefOwnPtr<CefApiVersionTestScopedClient> SetOwnPtrClientAndReturn(
      CefOwnPtr<CefApiVersionTestScopedClient> val) = 0;

#if CEF_API_REMOVED(13302)
  ///
  /// Set a child object. Returns the value from
  /// CefApiVersionTestScopedClient::GetValue(). This tests input of a client-
  /// side child object type and execution as the parent type.
  ///
  /*--cef(removed=13302)--*/
  virtual int SetChildOwnPtrClient(
      CefOwnPtr<CefApiVersionTestScopedClientChild> val) = 0;

  ///
  /// Set a child object. Returns the object as the parent type. This tests
  /// input of a client-side child object type and return as the parent type.
  ///
  /*--cef(removed=13302)--*/
  virtual CefOwnPtr<CefApiVersionTestScopedClient>
  SetChildOwnPtrClientAndReturnParent(
      CefOwnPtr<CefApiVersionTestScopedClientChild> val) = 0;
#endif  // CEF_API_REMOVED(13302)

#if CEF_API_ADDED(13302)
  ///
  /// Set a child object. Returns the value from
  /// CefApiVersionTestScopedClient::GetValue(). This tests input of a client-
  /// side child object type and execution as the parent type.
  ///
  /*--cef(added=13302,capi_name=set_child_own_ptr_client_v2)--*/
  virtual int SetChildOwnPtrClient(
      CefOwnPtr<CefApiVersionTestScopedClientChildV2> val) = 0;

  ///
  /// Set a child object. Returns the object as the parent type. This tests
  /// input of a client-side child object type and return as the parent type.
  ///
  /*--cef(added=13302,
          capi_name=set_child_own_ptr_client_and_return_parent_v2)--*/
  virtual CefOwnPtr<CefApiVersionTestScopedClient>
  SetChildOwnPtrClientAndReturnParent(
      CefOwnPtr<CefApiVersionTestScopedClientChildV2> val) = 0;
#endif  // CEF_API_ADDED(13302)

  // LIBRARY-SIDE RAWPTR VALUES

  ///
  /// Set an object. Returns the value from
  /// CefApiVersionTestScopedLibrary::GetValue().
  /// This tests input and execution of a library-side object type.
  ///
  /*--cef()--*/
  virtual int SetRawPtrLibrary(
      CefRawPtr<CefApiVersionTestScopedLibrary> val) = 0;

  ///
  /// Set a child object. Returns the value from
  /// CefApiVersionTestScopedLibrary::GetValue(). This tests input of a library-
  /// side child object type and execution as the parent type.
  ///
  /*--cef()--*/
  virtual int SetChildRawPtrLibrary(
      CefRawPtr<CefApiVersionTestScopedLibraryChild> val) = 0;

  // LIBRARY-SIDE RAWPTR LIST VALUES

  // Test both with and without a typedef.
  typedef std::vector<CefRawPtr<CefApiVersionTestScopedLibrary>>
      RawPtrLibraryList;

  ///
  /// Set an object list vlaue.
  ///
  /*--cef()--*/
  virtual bool SetRawPtrLibraryList(
      const std::vector<CefRawPtr<CefApiVersionTestScopedLibrary>>& val,
      int val1,
      int val2) = 0;

  // CLIENT-SIDE RAWPTR VALUES

  ///
  /// Set an object. Returns the value from
  /// CefApiVersionTestScopedClient::GetValue().
  /// This tests input and execution of a client-side object type.
  ///
  /*--cef()--*/
  virtual int SetRawPtrClient(CefRawPtr<CefApiVersionTestScopedClient> val) = 0;

#if CEF_API_REMOVED(13302)
  ///
  /// Set a child object. Returns the value from
  /// CefApiVersionTestScopedClient::GetValue(). This tests input of a client-
  /// side child object type and execution as the parent type.
  ///
  /*--cef(removed=13302)--*/
  virtual int SetChildRawPtrClient(
      CefRawPtr<CefApiVersionTestScopedClientChild> val) = 0;
#endif

#if CEF_API_ADDED(13302)
  ///
  /// Set a child object. Returns the value from
  /// CefApiVersionTestScopedClient::GetValue(). This tests input of a client-
  /// side child object type and execution as the parent type.
  ///
  /*--cef(added=13302,capi_name=set_child_raw_ptr_client_v2)--*/
  virtual int SetChildRawPtrClient(
      CefRawPtr<CefApiVersionTestScopedClientChildV2> val) = 0;
#endif

  // CLIENT-SIDE RAWPTR LIST VALUES

  // Test both with and without a typedef.
  typedef std::vector<CefRawPtr<CefApiVersionTestScopedClient>>
      RawPtrClientList;

  ///
  /// Set an object list vlaue.
  ///
  /*--cef()--*/
  virtual bool SetRawPtrClientList(
      const std::vector<CefRawPtr<CefApiVersionTestScopedClient>>& val,
      int val1,
      int val2) = 0;
};

// REFPTR TYPES

///
/// Library-side test object for RefPtr.
///
/*--cef(source=library)--*/
class CefApiVersionTestRefPtrLibrary : public CefBaseRefCounted {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefApiVersionTestRefPtrLibrary> Create();

  // NOTE: Example of static method versioning.

#if CEF_API_ADDED(13301)
  ///
  /// Create the test object with default value.
  ///
  /*--cef(added=13301,capi_name=create_with_default)--*/
  static CefRefPtr<CefApiVersionTestRefPtrLibrary> Create(int value);
#endif

  // NOTE: API that has remained unchanged from the original version.
  // This will be ordered first in the C API struct.

  ///
  /// Return a legacy value.
  ///
  /*--cef()--*/
  virtual int GetValueLegacy() = 0;

  ///
  /// Set a legacy value.
  ///
  /*--cef()--*/
  virtual void SetValueLegacy(int value) = 0;

  // NOTE: Experimental API that is only available when CEF_API_VERSION is
  // undefined. This will be ordered last in the C API struct.

#if CEF_API_ADDED(CEF_EXPERIMENTAL)
  ///
  /// Return an experimental value.
  ///
  /*--cef(added=experimental)--*/
  virtual int GetValueExp() = 0;

  ///
  /// Set an experimental value.
  ///
  /*--cef(added=experimental)--*/
  virtual void SetValueExp(int value) = 0;
#endif

  // NOTE: Example of API changing over time. Name needs to change because the
  // return value is the same. Will be ordered by 'added' version in the C API
  // struct.

#if CEF_API_REMOVED(13301)
  ///
  /// Return a value. This is replaced by GetValueV1 in version 13301.
  ///
  /*--cef(removed=13301)--*/
  virtual int GetValue() = 0;

  ///
  /// Set a value. This is replaced by SetValueV1 in version 13301.
  ///
  /*--cef(removed=13301)--*/
  virtual void SetValue(int value) = 0;
#endif

#if CEF_API_RANGE(13301, 13302)
  ///
  /// Return a value (V1). This replaces GetValue in version 13301 and is
  /// replaced by CefValueV2 in version 13302.
  ///
  /*--cef(added=13301,removed=13302)--*/
  virtual int GetValueV1() = 0;

  ///
  /// Set a value (V1). This replaces SetValue in version 13301 and is replaced
  /// by SefValueV2 in version 13302.
  ///
  /*--cef(added=13301,removed=13302)--*/
  virtual void SetValueV1(int value) = 0;
#endif

#if CEF_API_ADDED(13302)
  ///
  /// Return a value (V2). This replaces GetValueV1 in version 13302.
  ///
  /*--cef(added=13302)--*/
  virtual int GetValueV2() = 0;

  ///
  /// Set a value (V2). This replaces SetValueV1 in version 13302.
  ///
  /*--cef(added=13302)--*/
  virtual void SetValueV2(int value) = 0;
#endif
};

// NOTE: Child has 1 version, parent has multiple versions.

///
/// Library-side child test object for RefPtr.
///
/*--cef(source=library)--*/
class CefApiVersionTestRefPtrLibraryChild
    : public CefApiVersionTestRefPtrLibrary {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefApiVersionTestRefPtrLibraryChild> Create();

#if CEF_API_ADDED(13301)
  ///
  /// Create the test object with default value.
  ///
  /*--cef(added=13301,capi_name=create_with_default)--*/
  static CefRefPtr<CefApiVersionTestRefPtrLibraryChild> Create(int value,
                                                               int other_value);
#endif

  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetOtherValue() = 0;

  ///
  /// Set a value.
  ///
  /*--cef()--*/
  virtual void SetOtherValue(int value) = 0;
};

// NOTE: Child changes at each version.

#if CEF_API_REMOVED(13301)
///
/// Another library-side child test object for RefPtr. This is replaced
/// by CefApiVersionTestRefPtrLibraryChildChildV1 in version 13301.
///
/*--cef(source=library,removed=13301)--*/
class CefApiVersionTestRefPtrLibraryChildChild
    : public CefApiVersionTestRefPtrLibraryChild {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefApiVersionTestRefPtrLibraryChildChild> Create();

  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetOtherOtherValue() = 0;

  ///
  /// Set a value.
  ///
  /*--cef()--*/
  virtual void SetOtherOtherValue(int value) = 0;
};
#endif  // CEF_API_REMOVED(13301)

#if CEF_API_RANGE(13301, 13302)
///
/// Another library-side child test object for RefPtr. This replaces
/// CefApiVersionTestRefPtrLibraryChildChild in version 13301 and is
/// replaced by CefApiVersionTestRefPtrLibraryChildChildV2 in version 13302.
///
/*--cef(source=library,added=13301,removed=13302)--*/
class CefApiVersionTestRefPtrLibraryChildChildV1
    : public CefApiVersionTestRefPtrLibraryChild {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefApiVersionTestRefPtrLibraryChildChildV1> Create();

  ///
  /// Create the test object with default value.
  ///
  /*--cef(capi_name=create_with_default)--*/
  static CefRefPtr<CefApiVersionTestRefPtrLibraryChildChildV1>
  Create(int value, int other_value, int other_other_value);

  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetOtherOtherValue() = 0;

  ///
  /// Set a value.
  ///
  /*--cef()--*/
  virtual void SetOtherOtherValue(int value) = 0;
};
#endif  // CEF_API_RANGE(13301, 13302)

#if CEF_API_ADDED(13302)
///
/// Another library-side child test object for RefPtr. This replaces
/// CefApiVersionTestRefPtrLibraryChildChildV1 in version 13302.
///
/*--cef(source=library,added=13302)--*/
class CefApiVersionTestRefPtrLibraryChildChildV2
    : public CefApiVersionTestRefPtrLibraryChild {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefApiVersionTestRefPtrLibraryChildChildV2> Create();

  // NOTE: Redundant use of 'added' here will be ignored.

  ///
  /// Create the test object with default value.
  ///
  /*--cef(added=13302,capi_name=create_with_default)--*/
  static CefRefPtr<CefApiVersionTestRefPtrLibraryChildChildV2>
  Create(int value, int other_value, int other_other_value);

  // NOTE: Class name changed so we don't need to also change the method name.

  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetOtherOtherValue() = 0;

  ///
  /// Set a value (v3).
  ///
  /*--cef()--*/
  virtual void SetOtherOtherValue(int value) = 0;
};
#endif  // CEF_API_ADDED(13302)

///
/// Client-side test object for RefPtr.
///
/*--cef(source=client)--*/
class CefApiVersionTestRefPtrClient : public virtual CefBaseRefCounted {
 public:
  // NOTE: API that has remained unchanged from the original version.
  // This will be ordered first in the C API struct.

  ///
  /// Return a legacy value.
  ///
  /*--cef()--*/
  virtual int GetValueLegacy() = 0;

  // NOTE: Experimental API that is only available when CEF_API_VERSION is
  // undefined. This will be ordered last in the C API struct.

#if CEF_API_ADDED(CEF_EXPERIMENTAL)
  ///
  /// Return an experimental value.
  ///
  /*--cef(added=experimental)--*/
  virtual int GetValueExp() = 0;
#endif

  // NOTE: Example of API changing over time. Name needs to change because the
  // return value is the same.  Will be ordered by 'added' version in the C API
  // struct.

  // Available in version < 13301
#if CEF_API_REMOVED(13301)
  ///
  /// Return a value. This is replaced with GetValueV1 in version 13301.
  ///
  /*--cef(removed=13301)--*/
  virtual int GetValue() = 0;
#endif

#if CEF_API_RANGE(13301, 13302)
  ///
  /// Return a value (V1). This replaces GetValue in version 13301 and is
  /// replaced with GetValueV2 in version 13302.
  ///
  /*--cef(added=13301,removed=13302)--*/
  virtual int GetValueV1() = 0;
#endif

#if CEF_API_ADDED(13302)
  ///
  /// Return a value (V2). This replaces GetValueV1 in version 13302.
  ///
  /*--cef(added=13302)--*/
  virtual int GetValueV2() = 0;
#endif
};

// NOTE: Children have multiple versions, parent has multiple versions.
// NOTE: Example of both class and method versioning.

#if CEF_API_REMOVED(13302)
///
/// Client-side child test object for RefPtr. This is replaced with
/// CefApiVersionTestRefPtrClientChildV2 in version 13302.
///
/*--cef(source=client,removed=13302)--*/
class CefApiVersionTestRefPtrClientChild
    : public CefApiVersionTestRefPtrClient {
 public:
  // NOTE: Order of added/removed definitions doesn't matter, provided the order
  // doesn't change in the future.

#if CEF_API_ADDED(13301)
  ///
  /// Return a value (V1). This replaces GetOtherValue in version 13301.
  ///
  /*--cef(added=13301)--*/
  virtual int GetOtherValueV1() = 0;
#endif

#if CEF_API_REMOVED(13301)
  ///
  /// Return a value. This is replaced with GetOtherValueV1 in version 13301.
  ///
  /*--cef(removed=13301)--*/
  virtual int GetOtherValue() = 0;
#endif
};
#endif  // CEF_API_REMOVED(13302)

#if CEF_API_ADDED(13302)
///
/// Client-side child test object for RefPtr. This replaces
/// CefApiVersionTestRefPtrClientChild in version 13302.
///
/*--cef(source=client,added=13302)--*/
class CefApiVersionTestRefPtrClientChildV2
    : public CefApiVersionTestRefPtrClient {
 public:
  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetOtherValue() = 0;

#if CEF_API_ADDED(13303)
  ///
  /// Return another value.
  ///
  /*--cef(added=13303)--*/
  virtual int GetAnotherValue() = 0;
#endif
};
#endif  // CEF_API_ADDED(13302)

// OWNPTR/RAWPTR TYPES

///
/// Library-side test object for OwnPtr/RawPtr.
///
/*--cef(source=library)--*/
class CefApiVersionTestScopedLibrary : public CefBaseScoped {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefOwnPtr<CefApiVersionTestScopedLibrary> Create();

  // NOTE: Example of static method versioning.

#if CEF_API_ADDED(13301)
  ///
  /// Create the test object with default value.
  ///
  /*--cef(added=13301,capi_name=create_with_default)--*/
  static CefOwnPtr<CefApiVersionTestScopedLibrary> Create(int value);
#endif

  // NOTE: API that has remained unchanged from the original version.
  // This will be ordered first in the C API struct.

  ///
  /// Return a legacy value.
  ///
  /*--cef()--*/
  virtual int GetValueLegacy() = 0;

  ///
  /// Set a legacy value.
  ///
  /*--cef()--*/
  virtual void SetValueLegacy(int value) = 0;

  // NOTE: Experimental API that is only available when CEF_API_VERSION is
  // undefined. This will be ordered last in the C API struct.

#if CEF_API_ADDED(CEF_EXPERIMENTAL)
  ///
  /// Return an experimental value.
  ///
  /*--cef(added=experimental)--*/
  virtual int GetValueExp() = 0;

  ///
  /// Set an experimental value.
  ///
  /*--cef(added=experimental)--*/
  virtual void SetValueExp(int value) = 0;
#endif

  // NOTE: Example of API changing over time. Name needs to change because the
  // return value is the same. Will be ordered by 'added' version in the C API
  // struct.

#if CEF_API_REMOVED(13301)
  ///
  /// Return a value. This is replaced by GetValueV1 in version 13301.
  ///
  /*--cef(removed=13301)--*/
  virtual int GetValue() = 0;

  ///
  /// Set a value. This is replaced by SetValueV1 in version 13301.
  ///
  /*--cef(removed=13301)--*/
  virtual void SetValue(int value) = 0;
#endif

#if CEF_API_RANGE(13301, 13302)
  ///
  /// Return a value (V1). This replaces GetValue in version 13301 and is
  /// replaced by CefValueV2 in version 13302.
  ///
  /*--cef(added=13301,removed=13302)--*/
  virtual int GetValueV1() = 0;

  ///
  /// Set a value (V1). This replaces SetValue in version 13301 and is replaced
  /// by SefValueV2 in version 13302.
  ///
  /*--cef(added=13301,removed=13302)--*/
  virtual void SetValueV1(int value) = 0;
#endif

#if CEF_API_ADDED(13302)
  ///
  /// Return a value (V2). This replaces GetValueV1 in version 13302.
  ///
  /*--cef(added=13302)--*/
  virtual int GetValueV2() = 0;

  ///
  /// Set a value (V2). This replaces SetValueV1 in version 13302.
  ///
  /*--cef(added=13302)--*/
  virtual void SetValueV2(int value) = 0;
#endif
};

// NOTE: Child has 1 version, parent has multiple versions.

///
/// Library-side child test object for OwnPtr/RawPtr.
///
/*--cef(source=library)--*/
class CefApiVersionTestScopedLibraryChild
    : public CefApiVersionTestScopedLibrary {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefOwnPtr<CefApiVersionTestScopedLibraryChild> Create();

#if CEF_API_ADDED(13301)
  ///
  /// Create the test object with default value.
  ///
  /*--cef(added=13301,capi_name=create_with_default)--*/
  static CefOwnPtr<CefApiVersionTestScopedLibraryChild> Create(int value,
                                                               int other_value);
#endif

  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetOtherValue() = 0;

  ///
  /// Set a value.
  ///
  /*--cef()--*/
  virtual void SetOtherValue(int value) = 0;
};

// NOTE: Child changes at each version.

#if CEF_API_REMOVED(13301)
///
/// Another library-side child test object for OwnPtr/RawPtr. This is replaced
/// by CefApiVersionTestScopedLibraryChildChildV1 in version 13301.
///
/*--cef(source=library,removed=13301)--*/
class CefApiVersionTestScopedLibraryChildChild
    : public CefApiVersionTestScopedLibraryChild {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefOwnPtr<CefApiVersionTestScopedLibraryChildChild> Create();

  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetOtherOtherValue() = 0;

  ///
  /// Set a value.
  ///
  /*--cef()--*/
  virtual void SetOtherOtherValue(int value) = 0;
};
#endif  // CEF_API_REMOVED(13301)

#if CEF_API_RANGE(13301, 13302)
///
/// Another library-side child test object for OwnPtr/RawPtr. This replaces
/// CefApiVersionTestScopedLibraryChildChild in version 13301 and is
/// replaced by CefApiVersionTestScopedLibraryChildChildV2 in version 13302.
///
/*--cef(source=library,added=13301,removed=13302)--*/
class CefApiVersionTestScopedLibraryChildChildV1
    : public CefApiVersionTestScopedLibraryChild {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefOwnPtr<CefApiVersionTestScopedLibraryChildChildV1> Create();

  ///
  /// Create the test object with default value.
  ///
  /*--cef(capi_name=create_with_default)--*/
  static CefOwnPtr<CefApiVersionTestScopedLibraryChildChildV1>
  Create(int value, int other_value, int other_other_value);

  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetOtherOtherValue() = 0;

  ///
  /// Set a value.
  ///
  /*--cef()--*/
  virtual void SetOtherOtherValue(int value) = 0;
};
#endif  // CEF_API_RANGE(13301, 13302)

#if CEF_API_ADDED(13302)
///
/// Another library-side child test object for OwnPtr/RawPtr. This replaces
/// CefApiVersionTestScopedLibraryChildChildV1 in version 13302.
///
/*--cef(source=library,added=13302)--*/
class CefApiVersionTestScopedLibraryChildChildV2
    : public CefApiVersionTestScopedLibraryChild {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefOwnPtr<CefApiVersionTestScopedLibraryChildChildV2> Create();

  // NOTE: Redundant use of 'added' here will be ignored.

  ///
  /// Create the test object with default value.
  ///
  /*--cef(added=13302,capi_name=create_with_default)--*/
  static CefOwnPtr<CefApiVersionTestScopedLibraryChildChildV2>
  Create(int value, int other_value, int other_other_value);

  // NOTE: Class name changed so we don't need to also change the method name.

  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetOtherOtherValue() = 0;

  ///
  /// Set a value (v3).
  ///
  /*--cef()--*/
  virtual void SetOtherOtherValue(int value) = 0;
};
#endif  // CEF_API_ADDED(13302)

///
/// Client-side test object for OwnPtr/RawPtr.
///
/*--cef(source=client)--*/
class CefApiVersionTestScopedClient : public virtual CefBaseScoped {
 public:
  // NOTE: API that has remained unchanged from the original version.
  // This will be ordered first in the C API struct.

  ///
  /// Return a legacy value.
  ///
  /*--cef()--*/
  virtual int GetValueLegacy() = 0;

  // NOTE: Experimental API that is only available when CEF_API_VERSION is
  // undefined. This will be ordered last in the C API struct.

#if CEF_API_ADDED(CEF_EXPERIMENTAL)
  ///
  /// Return an experimental value.
  ///
  /*--cef(added=experimental)--*/
  virtual int GetValueExp() = 0;
#endif

  // NOTE: Example of API changing over time. Name needs to change because the
  // return value is the same.  Will be ordered by 'added' version in the C API
  // struct.

  // Available in version < 13301
#if CEF_API_REMOVED(13301)
  ///
  /// Return a value. This is replaced with GetValueV1 in version 13301.
  ///
  /*--cef(removed=13301)--*/
  virtual int GetValue() = 0;
#endif

#if CEF_API_RANGE(13301, 13302)
  ///
  /// Return a value (V1). This replaces GetValue in version 13301 and is
  /// replaced with GetValueV2 in version 13302.
  ///
  /*--cef(added=13301,removed=13302)--*/
  virtual int GetValueV1() = 0;
#endif

#if CEF_API_ADDED(13302)
  ///
  /// Return a value (V2). This replaces GetValueV1 in version 13302.
  ///
  /*--cef(added=13302)--*/
  virtual int GetValueV2() = 0;
#endif
};

// NOTE: Children have multiple versions, parent has multiple versions.
// NOTE: Example of both class and method versioning.

#if CEF_API_REMOVED(13302)
///
/// Client-side child test object for OwnPtr/RawPtr. This is replaced with
/// CefApiVersionTestScopedClientChildV2 in version 13302.
///
/*--cef(source=client,removed=13302)--*/
class CefApiVersionTestScopedClientChild
    : public CefApiVersionTestScopedClient {
 public:
  // NOTE: Order of added/removed definitions doesn't matter, provided the order
  // doesn't change in the future.

#if CEF_API_ADDED(13301)
  ///
  /// Return a value (V1). This replaces GetOtherValue in version 13301.
  ///
  /*--cef(added=13301)--*/
  virtual int GetOtherValueV1() = 0;
#endif

#if CEF_API_REMOVED(13301)
  ///
  /// Return a value. This is replaced with GetOtherValueV1 in version 13301.
  ///
  /*--cef(removed=13301)--*/
  virtual int GetOtherValue() = 0;
#endif
};
#endif  // CEF_API_REMOVED(13302)

#if CEF_API_ADDED(13302)
///
/// Client-side child test object for OwnPtr/RawPtr. This replaces
/// CefApiVersionTestScopedClientChild in version 13302.
///
/*--cef(source=client,added=13302)--*/
class CefApiVersionTestScopedClientChildV2
    : public CefApiVersionTestScopedClient {
 public:
  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetOtherValue() = 0;

#if CEF_API_ADDED(13303)
  ///
  /// Return another value.
  ///
  /*--cef(added=13303)--*/
  virtual int GetAnotherValue() = 0;
#endif
};
#endif  // CEF_API_ADDED(13302)

#endif  // CEF_INCLUDE_TEST_CEF_API_VERSION_TEST_H_
