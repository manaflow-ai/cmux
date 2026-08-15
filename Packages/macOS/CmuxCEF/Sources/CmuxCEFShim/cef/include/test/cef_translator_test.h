// Copyright (c) 2015 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_TEST_CEF_TRANSLATOR_TEST_H_
#define CEF_INCLUDE_TEST_CEF_TRANSLATOR_TEST_H_
#pragma once

#if !defined(BUILDING_CEF_SHARED) && !defined(WRAPPING_CEF_SHARED) && \
    !defined(UNIT_TEST)
#error This file can be included for unit tests only
#endif

#include <map>
#include <vector>

#include "include/cef_base.h"

class CefTranslatorTestRefPtrClient;
class CefTranslatorTestRefPtrClientChild;
class CefTranslatorTestRefPtrLibrary;
class CefTranslatorTestRefPtrLibraryChild;
class CefTranslatorTestScopedClient;
class CefTranslatorTestScopedClientChild;
class CefTranslatorTestScopedLibrary;
class CefTranslatorTestScopedLibraryChild;

// Test values.
#define TEST_INT_VAL 5
#define TEST_INT_VAL2 60
#define TEST_BOOL_VAL true
#define TEST_DOUBLE_VAL 4.543
#define TEST_LONG_VAL -65
#define TEST_SIZET_VAL 3U
#define TEST_STRING_VAL "My test string"
#define TEST_STRING_VAL2 "My 2nd test string"
#define TEST_STRING_VAL3 "My 3rd test string"
#define TEST_STRING_KEY "key0"
#define TEST_STRING_KEY2 "key1"
#define TEST_STRING_KEY3 "key2"
#define TEST_X_VAL 44
#define TEST_Y_VAL 754
#define TEST_X_VAL2 900
#define TEST_Y_VAL2 300

///
/// Class for testing all of the possible data transfer types.
///
/*--cef(source=library)--*/
class CefTranslatorTest : public CefBaseRefCounted {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefTranslatorTest> Create();

  // PRIMITIVE VALUES

  ///
  /// Return a void value.
  ///
  /*--cef()--*/
  virtual void GetVoid() = 0;

  ///
  /// Return a bool value.
  ///
  /*--cef()--*/
  virtual bool GetBool() = 0;

  ///
  /// Return an int value.
  ///
  /*--cef()--*/
  virtual int GetInt() = 0;

  ///
  /// Return a double value.
  ///
  /*--cef()--*/
  virtual double GetDouble() = 0;

  ///
  /// Return a long value.
  ///
  /*--cef()--*/
  virtual long GetLong() = 0;

  ///
  /// Return a size_t value.
  ///
  /*--cef()--*/
  virtual size_t GetSizet() = 0;

  ///
  /// Set a void value.
  ///
  /*--cef()--*/
  virtual bool SetVoid() = 0;

  ///
  /// Set a bool value.
  ///
  /*--cef()--*/
  virtual bool SetBool(bool val) = 0;

  ///
  /// Set an int value.
  ///
  /*--cef()--*/
  virtual bool SetInt(int val) = 0;

  ///
  /// Set a double value.
  ///
  /*--cef()--*/
  virtual bool SetDouble(double val) = 0;

  ///
  /// Set a long value.
  ///
  /*--cef()--*/
  virtual bool SetLong(long val) = 0;

  ///
  /// Set a size_t value.
  ///
  /*--cef()--*/
  virtual bool SetSizet(size_t val) = 0;

  // PRIMITIVE LIST VALUES

  // Test both with and without a typedef.
  typedef std::vector<int> IntList;

  ///
  /// Set a int list value.
  ///
  /*--cef()--*/
  virtual bool SetIntList(const std::vector<int>& val) = 0;

  ///
  /// Return an int list value by out-param.
  ///
  /*--cef(count_func=val:GetIntListSize)--*/
  virtual bool GetIntListByRef(IntList& val) = 0;

  ///
  /// Return the number of points that will be output above.
  ///
  /*--cef()--*/
  virtual size_t GetIntListSize() = 0;

  // STRING VALUES

  ///
  /// Return a string value.
  ///
  /*--cef()--*/
  virtual CefString GetString() = 0;

  ///
  /// Set a string value.
  ///
  /*--cef()--*/
  virtual bool SetString(const CefString& val) = 0;

  ///
  /// Return a string value by out-param.
  ///
  /*--cef()--*/
  virtual void GetStringByRef(CefString& val) = 0;

  // STRING LIST VALUES

  // Test both with and without a typedef.
  typedef std::vector<CefString> StringList;

  ///
  /// Set a string list value.
  ///
  /*--cef()--*/
  virtual bool SetStringList(const std::vector<CefString>& val) = 0;

  ///
  /// Return a string list value by out-param.
  ///
  /*--cef()--*/
  virtual bool GetStringListByRef(StringList& val) = 0;

  // STRING MAP VALUES

  // Test both with and without a typedef.
  typedef std::map<CefString, CefString> StringMap;

  ///
  /// Set a string map value.
  ///
  /*--cef()--*/
  virtual bool SetStringMap(const StringMap& val) = 0;

  ///
  /// Return a string map value by out-param.
  ///
  /*--cef()--*/
  virtual bool GetStringMapByRef(std::map<CefString, CefString>& val) = 0;

  // STRING MULTIMAP VALUES

  // Test both with and without a typedef.
  typedef std::multimap<CefString, CefString> StringMultimap;

  ///
  /// Set a string multimap value.
  ///
  /*--cef()--*/
  virtual bool SetStringMultimap(
      const std::multimap<CefString, CefString>& val) = 0;

  ///
  /// Return a string multimap value by out-param.
  ///
  /*--cef()--*/
  virtual bool GetStringMultimapByRef(StringMultimap& val) = 0;

  // STRUCT VALUES

  ///
  /// Return a point value.
  ///
  /*--cef()--*/
  virtual CefPoint GetPoint() = 0;

  ///
  /// Set a point value.
  ///
  /*--cef()--*/
  virtual bool SetPoint(const CefPoint& val) = 0;

  ///
  /// Return a point value by out-param.
  ///
  /*--cef()--*/
  virtual void GetPointByRef(CefPoint& val) = 0;

  // STRUCT LIST VALUES

  // Test both with and without a typedef.
  typedef std::vector<CefPoint> PointList;

  ///
  /// Set a point list vlaue.
  ///
  /*--cef()--*/
  virtual bool SetPointList(const std::vector<CefPoint>& val) = 0;

  ///
  /// Return a point list value by out-param.
  ///
  /*--cef(count_func=val:GetPointListSize)--*/
  virtual bool GetPointListByRef(PointList& val) = 0;

  ///
  /// Return the number of points that will be output above.
  ///
  /*--cef()--*/
  virtual size_t GetPointListSize() = 0;

  // LIBRARY-SIDE REFPTR VALUES

  ///
  /// Return an new library-side object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefTranslatorTestRefPtrLibrary> GetRefPtrLibrary(
      int val) = 0;

  ///
  /// Set an object. Returns the value from
  /// CefTranslatorTestRefPtrLibrary::GetValue().
  /// This tests input and execution of a library-side object type.
  ///
  /*--cef()--*/
  virtual int SetRefPtrLibrary(
      CefRefPtr<CefTranslatorTestRefPtrLibrary> val) = 0;

  ///
  /// Set an object. Returns the object passed in. This tests input and output
  /// of a library-side object type.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefTranslatorTestRefPtrLibrary> SetRefPtrLibraryAndReturn(
      CefRefPtr<CefTranslatorTestRefPtrLibrary> val) = 0;

  ///
  /// Set a child object. Returns the value from
  /// CefTranslatorTestRefPtrLibrary::GetValue(). This tests input of a library-
  /// side child object type and execution as the parent type.
  ///
  /*--cef()--*/
  virtual int SetChildRefPtrLibrary(
      CefRefPtr<CefTranslatorTestRefPtrLibraryChild> val) = 0;

  ///
  /// Set a child object. Returns the object as the parent type. This tests
  /// input of a library-side child object type and return as the parent type.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefTranslatorTestRefPtrLibrary>
  SetChildRefPtrLibraryAndReturnParent(
      CefRefPtr<CefTranslatorTestRefPtrLibraryChild> val) = 0;

  // LIBRARY-SIDE REFPTR LIST VALUES

  // Test both with and without a typedef.
  typedef std::vector<CefRefPtr<CefTranslatorTestRefPtrLibrary>>
      RefPtrLibraryList;

  ///
  /// Set an object list vlaue.
  ///
  /*--cef()--*/
  virtual bool SetRefPtrLibraryList(
      const std::vector<CefRefPtr<CefTranslatorTestRefPtrLibrary>>& val,
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
  /// CefTranslatorTestRefPtrClient::GetValue().
  /// This tests input and execution of a client-side object type.
  ///
  /*--cef()--*/
  virtual int SetRefPtrClient(CefRefPtr<CefTranslatorTestRefPtrClient> val) = 0;

  ///
  /// Set an object. Returns the handler passed in. This tests input and output
  /// of a client-side object type.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefTranslatorTestRefPtrClient> SetRefPtrClientAndReturn(
      CefRefPtr<CefTranslatorTestRefPtrClient> val) = 0;

  ///
  /// Set a child object. Returns the value from
  /// CefTranslatorTestRefPtrClient::GetValue(). This tests input of a client-
  /// side child object type and execution as the parent type.
  ///
  /*--cef()--*/
  virtual int SetChildRefPtrClient(
      CefRefPtr<CefTranslatorTestRefPtrClientChild> val) = 0;

  ///
  /// Set a child object. Returns the object as the parent type. This tests
  /// input of a client-side child object type and return as the parent type.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefTranslatorTestRefPtrClient>
  SetChildRefPtrClientAndReturnParent(
      CefRefPtr<CefTranslatorTestRefPtrClientChild> val) = 0;

  // CLIENT-SIDE REFPTR LIST VALUES

  // Test both with and without a typedef.
  typedef std::vector<CefRefPtr<CefTranslatorTestRefPtrClient>>
      RefPtrClientList;

  ///
  /// Set an object list vlaue.
  ///
  /*--cef()--*/
  virtual bool SetRefPtrClientList(
      const std::vector<CefRefPtr<CefTranslatorTestRefPtrClient>>& val,
      int val1,
      int val2) = 0;

  ///
  /// Return an object list value by out-param.
  ///
  /*--cef(count_func=val:GetRefPtrLibraryListSize)--*/
  virtual bool GetRefPtrClientListByRef(
      RefPtrClientList& val,
      CefRefPtr<CefTranslatorTestRefPtrClient> val1,
      CefRefPtr<CefTranslatorTestRefPtrClient> val2) = 0;

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
  virtual CefOwnPtr<CefTranslatorTestScopedLibrary> GetOwnPtrLibrary(
      int val) = 0;

  ///
  /// Set an object. Returns the value from
  /// CefTranslatorTestScopedLibrary::GetValue().
  /// This tests input and execution of a library-side object type.
  ///
  /*--cef()--*/
  virtual int SetOwnPtrLibrary(
      CefOwnPtr<CefTranslatorTestScopedLibrary> val) = 0;

  ///
  /// Set an object. Returns the object passed in. This tests input and output
  /// of a library-side object type.
  ///
  /*--cef()--*/
  virtual CefOwnPtr<CefTranslatorTestScopedLibrary> SetOwnPtrLibraryAndReturn(
      CefOwnPtr<CefTranslatorTestScopedLibrary> val) = 0;

  ///
  /// Set a child object. Returns the value from
  /// CefTranslatorTestScopedLibrary::GetValue(). This tests input of a library-
  /// side child object type and execution as the parent type.
  ///
  /*--cef()--*/
  virtual int SetChildOwnPtrLibrary(
      CefOwnPtr<CefTranslatorTestScopedLibraryChild> val) = 0;

  ///
  /// Set a child object. Returns the object as the parent type. This tests
  /// input of a library-side child object type and return as the parent type.
  ///
  /*--cef()--*/
  virtual CefOwnPtr<CefTranslatorTestScopedLibrary>
  SetChildOwnPtrLibraryAndReturnParent(
      CefOwnPtr<CefTranslatorTestScopedLibraryChild> val) = 0;

  // CLIENT-SIDE OWNPTR VALUES

  ///
  /// Set an object. Returns the value from
  /// CefTranslatorTestScopedClient::GetValue().
  /// This tests input and execution of a client-side object type.
  ///
  /*--cef()--*/
  virtual int SetOwnPtrClient(CefOwnPtr<CefTranslatorTestScopedClient> val) = 0;

  ///
  /// Set an object. Returns the handler passed in. This tests input and output
  /// of a client-side object type.
  ///
  /*--cef()--*/
  virtual CefOwnPtr<CefTranslatorTestScopedClient> SetOwnPtrClientAndReturn(
      CefOwnPtr<CefTranslatorTestScopedClient> val) = 0;

  ///
  /// Set a child object. Returns the value from
  /// CefTranslatorTestScopedClient::GetValue(). This tests input of a client-
  /// side child object type and execution as the parent type.
  ///
  /*--cef()--*/
  virtual int SetChildOwnPtrClient(
      CefOwnPtr<CefTranslatorTestScopedClientChild> val) = 0;

  ///
  /// Set a child object. Returns the object as the parent type. This tests
  /// input of a client-side child object type and return as the parent type.
  ///
  /*--cef()--*/
  virtual CefOwnPtr<CefTranslatorTestScopedClient>
  SetChildOwnPtrClientAndReturnParent(
      CefOwnPtr<CefTranslatorTestScopedClientChild> val) = 0;

  // LIBRARY-SIDE RAWPTR VALUES

  ///
  /// Set an object. Returns the value from
  /// CefTranslatorTestScopedLibrary::GetValue().
  /// This tests input and execution of a library-side object type.
  ///
  /*--cef()--*/
  virtual int SetRawPtrLibrary(
      CefRawPtr<CefTranslatorTestScopedLibrary> val) = 0;

  ///
  /// Set a child object. Returns the value from
  /// CefTranslatorTestScopedLibrary::GetValue(). This tests input of a library-
  /// side child object type and execution as the parent type.
  ///
  /*--cef()--*/
  virtual int SetChildRawPtrLibrary(
      CefRawPtr<CefTranslatorTestScopedLibraryChild> val) = 0;

  // LIBRARY-SIDE RAWPTR LIST VALUES

  // Test both with and without a typedef.
  typedef std::vector<CefRawPtr<CefTranslatorTestScopedLibrary>>
      RawPtrLibraryList;

  ///
  /// Set an object list vlaue.
  ///
  /*--cef()--*/
  virtual bool SetRawPtrLibraryList(
      const std::vector<CefRawPtr<CefTranslatorTestScopedLibrary>>& val,
      int val1,
      int val2) = 0;

  // CLIENT-SIDE RAWPTR VALUES

  ///
  /// Set an object. Returns the value from
  /// CefTranslatorTestScopedClient::GetValue().
  /// This tests input and execution of a client-side object type.
  ///
  /*--cef()--*/
  virtual int SetRawPtrClient(CefRawPtr<CefTranslatorTestScopedClient> val) = 0;

  ///
  /// Set a child object. Returns the value from
  /// CefTranslatorTestScopedClient::GetValue(). This tests input of a client-
  /// side child object type and execution as the parent type.
  ///
  /*--cef()--*/
  virtual int SetChildRawPtrClient(
      CefRawPtr<CefTranslatorTestScopedClientChild> val) = 0;

  // CLIENT-SIDE RAWPTR LIST VALUES

  // Test both with and without a typedef.
  typedef std::vector<CefRawPtr<CefTranslatorTestScopedClient>>
      RawPtrClientList;

  ///
  /// Set an object list vlaue.
  ///
  /*--cef()--*/
  virtual bool SetRawPtrClientList(
      const std::vector<CefRawPtr<CefTranslatorTestScopedClient>>& val,
      int val1,
      int val2) = 0;
};

///
/// Library-side test object for RefPtr.
///
/*--cef(source=library)--*/
class CefTranslatorTestRefPtrLibrary : public CefBaseRefCounted {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefTranslatorTestRefPtrLibrary> Create(int value);

  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetValue() = 0;

  ///
  /// Set a value.
  ///
  /*--cef()--*/
  virtual void SetValue(int value) = 0;
};

///
/// Library-side child test object for RefPtr.
///
/*--cef(source=library)--*/
class CefTranslatorTestRefPtrLibraryChild
    : public CefTranslatorTestRefPtrLibrary {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefTranslatorTestRefPtrLibraryChild> Create(int value,
                                                               int other_value);

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

///
/// Another library-side child test object for RefPtr.
///
/*--cef(source=library)--*/
class CefTranslatorTestRefPtrLibraryChildChild
    : public CefTranslatorTestRefPtrLibraryChild {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefTranslatorTestRefPtrLibraryChildChild>
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

///
/// Client-side test object for RefPtr.
///
/*--cef(source=client)--*/
class CefTranslatorTestRefPtrClient : public virtual CefBaseRefCounted {
 public:
  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetValue() = 0;
};

///
/// Client-side child test object for RefPtr.
///
/*--cef(source=client)--*/
class CefTranslatorTestRefPtrClientChild
    : public CefTranslatorTestRefPtrClient {
 public:
  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetOtherValue() = 0;
};

///
/// Library-side test object for OwnPtr/RawPtr.
///
/*--cef(source=library)--*/
class CefTranslatorTestScopedLibrary : public CefBaseScoped {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefOwnPtr<CefTranslatorTestScopedLibrary> Create(int value);

  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetValue() = 0;

  ///
  /// Set a value.
  ///
  /*--cef()--*/
  virtual void SetValue(int value) = 0;
};

///
/// Library-side child test object for OwnPtr/RawPtr.
///
/*--cef(source=library)--*/
class CefTranslatorTestScopedLibraryChild
    : public CefTranslatorTestScopedLibrary {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefOwnPtr<CefTranslatorTestScopedLibraryChild> Create(int value,
                                                               int other_value);

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

///
/// Another library-side child test object for OwnPtr/RawPtr.
///
/*--cef(source=library)--*/
class CefTranslatorTestScopedLibraryChildChild
    : public CefTranslatorTestScopedLibraryChild {
 public:
  ///
  /// Create the test object.
  ///
  /*--cef()--*/
  static CefOwnPtr<CefTranslatorTestScopedLibraryChildChild>
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

///
/// Client-side test object for OwnPtr/RawPtr.
///
/*--cef(source=client)--*/
class CefTranslatorTestScopedClient : public virtual CefBaseScoped {
 public:
  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetValue() = 0;
};

///
/// Client-side child test object for OwnPtr/RawPtr.
///
/*--cef(source=client)--*/
class CefTranslatorTestScopedClientChild
    : public CefTranslatorTestScopedClient {
 public:
  ///
  /// Return a value.
  ///
  /*--cef()--*/
  virtual int GetOtherValue() = 0;
};

#endif  // CEF_INCLUDE_TEST_CEF_TRANSLATOR_TEST_H_
