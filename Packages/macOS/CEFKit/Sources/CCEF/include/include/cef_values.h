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

#ifndef CEF_INCLUDE_CEF_VALUES_H_
#define CEF_INCLUDE_CEF_VALUES_H_
#pragma once

#include <vector>

#include "include/cef_base.h"

class CefBinaryValue;
class CefDictionaryValue;
class CefListValue;

typedef cef_value_type_t CefValueType;

///
/// Class that wraps other data value types. Complex types (binary, dictionary
/// and list) will be referenced but not owned by this object. Can be used on
/// any process and thread.
///
/*--cef(source=library)--*/
class CefValue : public virtual CefBaseRefCounted {
 public:
  ///
  /// Creates a new object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefValue> Create();

  ///
  /// Returns true if the underlying data is valid. This will always be true for
  /// simple types. For complex types (binary, dictionary and list) the
  /// underlying data may become invalid if owned by another object (e.g. list
  /// or dictionary) and that other object is then modified or destroyed. This
  /// value object can be re-used by calling Set*() even if the underlying data
  /// is invalid.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns true if the underlying data is owned by another object.
  ///
  /*--cef()--*/
  virtual bool IsOwned() = 0;

  ///
  /// Returns true if the underlying data is read-only. Some APIs may expose
  /// read-only objects.
  ///
  /*--cef()--*/
  virtual bool IsReadOnly() = 0;

  ///
  /// Returns true if this object and |that| object have the same underlying
  /// data. If true modifications to this object will also affect |that| object
  /// and vice-versa.
  ///
  /*--cef()--*/
  virtual bool IsSame(CefRefPtr<CefValue> that) = 0;

  ///
  /// Returns true if this object and |that| object have an equivalent
  /// underlying value but are not necessarily the same object.
  ///
  /*--cef()--*/
  virtual bool IsEqual(CefRefPtr<CefValue> that) = 0;

  ///
  /// Returns a copy of this object. The underlying data will also be copied.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefValue> Copy() = 0;

  ///
  /// Returns the underlying value type.
  ///
  /*--cef(default_retval=VTYPE_INVALID)--*/
  virtual CefValueType GetType() = 0;

  ///
  /// Returns the underlying value as type bool.
  ///
  /*--cef()--*/
  virtual bool GetBool() = 0;

  ///
  /// Returns the underlying value as type int.
  ///
  /*--cef()--*/
  virtual int GetInt() = 0;

  ///
  /// Returns the underlying value as type double.
  ///
  /*--cef()--*/
  virtual double GetDouble() = 0;

  ///
  /// Returns the underlying value as type string.
  ///
  /*--cef()--*/
  virtual CefString GetString() = 0;

  ///
  /// Returns the underlying value as type binary. The returned reference may
  /// become invalid if the value is owned by another object or if ownership is
  /// transferred to another object in the future. To maintain a reference to
  /// the value after assigning ownership to a dictionary or list pass this
  /// object to the SetValue() method instead of passing the returned reference
  /// to SetBinary().
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBinaryValue> GetBinary() = 0;

  ///
  /// Returns the underlying value as type dictionary. The returned reference
  /// may become invalid if the value is owned by another object or if ownership
  /// is transferred to another object in the future. To maintain a reference to
  /// the value after assigning ownership to a dictionary or list pass this
  /// object to the SetValue() method instead of passing the returned reference
  /// to SetDictionary().
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefDictionaryValue> GetDictionary() = 0;

  ///
  /// Returns the underlying value as type list. The returned reference may
  /// become invalid if the value is owned by another object or if ownership is
  /// transferred to another object in the future. To maintain a reference to
  /// the value after assigning ownership to a dictionary or list pass this
  /// object to the SetValue() method instead of passing the returned reference
  /// to SetList().
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefListValue> GetList() = 0;

  ///
  /// Sets the underlying value as type null. Returns true if the value was set
  /// successfully.
  ///
  /*--cef()--*/
  virtual bool SetNull() = 0;

  ///
  /// Sets the underlying value as type bool. Returns true if the value was set
  /// successfully.
  ///
  /*--cef()--*/
  virtual bool SetBool(bool value) = 0;

  ///
  /// Sets the underlying value as type int. Returns true if the value was set
  /// successfully.
  ///
  /*--cef()--*/
  virtual bool SetInt(int value) = 0;

  ///
  /// Sets the underlying value as type double. Returns true if the value was
  /// set successfully.
  ///
  /*--cef()--*/
  virtual bool SetDouble(double value) = 0;

  ///
  /// Sets the underlying value as type string. Returns true if the value was
  /// set successfully.
  ///
  /*--cef(optional_param=value)--*/
  virtual bool SetString(const CefString& value) = 0;

  ///
  /// Sets the underlying value as type binary. Returns true if the value was
  /// set successfully. This object keeps a reference to |value| and ownership
  /// of the underlying data remains unchanged.
  ///
  /*--cef()--*/
  virtual bool SetBinary(CefRefPtr<CefBinaryValue> value) = 0;

  ///
  /// Sets the underlying value as type dict. Returns true if the value was set
  /// successfully. This object keeps a reference to |value| and ownership of
  /// the underlying data remains unchanged.
  ///
  /*--cef()--*/
  virtual bool SetDictionary(CefRefPtr<CefDictionaryValue> value) = 0;

  ///
  /// Sets the underlying value as type list. Returns true if the value was set
  /// successfully. This object keeps a reference to |value| and ownership of
  /// the underlying data remains unchanged.
  ///
  /*--cef()--*/
  virtual bool SetList(CefRefPtr<CefListValue> value) = 0;
};

///
/// Class representing a binary value. Can be used on any process and thread.
///
/*--cef(source=library)--*/
class CefBinaryValue : public virtual CefBaseRefCounted {
 public:
  ///
  /// Creates a new object that is not owned by any other object. The specified
  /// |data| will be copied.
  ///
  /*--cef()--*/
  static CefRefPtr<CefBinaryValue> Create(const void* data, size_t data_size);

  ///
  /// Returns true if this object is valid. This object may become invalid if
  /// the underlying data is owned by another object (e.g. list or dictionary)
  /// and that other object is then modified or destroyed. Do not call any other
  /// methods if this method returns false.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns true if this object is currently owned by another object.
  ///
  /*--cef()--*/
  virtual bool IsOwned() = 0;

  ///
  /// Returns true if this object and |that| object have the same underlying
  /// data.
  ///
  /*--cef()--*/
  virtual bool IsSame(CefRefPtr<CefBinaryValue> that) = 0;

  ///
  /// Returns true if this object and |that| object have an equivalent
  /// underlying value but are not necessarily the same object.
  ///
  /*--cef()--*/
  virtual bool IsEqual(CefRefPtr<CefBinaryValue> that) = 0;

  ///
  /// Returns a copy of this object. The data in this object will also be
  /// copied.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBinaryValue> Copy() = 0;

  ///
  /// Returns a pointer to the beginning of the memory block.
  /// The returned pointer is valid as long as the CefBinaryValue is alive.
  ///
  /*--cef()--*/
  virtual const void* GetRawData() = 0;

  ///
  /// Returns the data size.
  ///
  /*--cef()--*/
  virtual size_t GetSize() = 0;

  ///
  /// Read up to |buffer_size| number of bytes into |buffer|. Reading begins at
  /// the specified byte |data_offset|. Returns the number of bytes read.
  ///
  /*--cef()--*/
  virtual size_t GetData(void* buffer,
                         size_t buffer_size,
                         size_t data_offset) = 0;
};

///
/// Class representing a dictionary value. Can be used on any process and
/// thread.
///
/*--cef(source=library)--*/
class CefDictionaryValue : public virtual CefBaseRefCounted {
 public:
  typedef std::vector<CefString> KeyList;

  ///
  /// Creates a new object that is not owned by any other object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefDictionaryValue> Create();

  ///
  /// Returns true if this object is valid. This object may become invalid if
  /// the underlying data is owned by another object (e.g. list or dictionary)
  /// and that other object is then modified or destroyed. Do not call any other
  /// methods if this method returns false.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns true if this object is currently owned by another object.
  ///
  /*--cef()--*/
  virtual bool IsOwned() = 0;

  ///
  /// Returns true if the values of this object are read-only. Some APIs may
  /// expose read-only objects.
  ///
  /*--cef()--*/
  virtual bool IsReadOnly() = 0;

  ///
  /// Returns true if this object and |that| object have the same underlying
  /// data. If true modifications to this object will also affect |that| object
  /// and vice-versa.
  ///
  /*--cef()--*/
  virtual bool IsSame(CefRefPtr<CefDictionaryValue> that) = 0;

  ///
  /// Returns true if this object and |that| object have an equivalent
  /// underlying value but are not necessarily the same object.
  ///
  /*--cef()--*/
  virtual bool IsEqual(CefRefPtr<CefDictionaryValue> that) = 0;

  ///
  /// Returns a writable copy of this object. If |exclude_empty_children| is
  /// true any empty dictionaries or lists will be excluded from the copy.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefDictionaryValue> Copy(bool exclude_empty_children) = 0;

  ///
  /// Returns the number of values.
  ///
  /*--cef()--*/
  virtual size_t GetSize() = 0;

  ///
  /// Removes all values. Returns true on success.
  ///
  /*--cef()--*/
  virtual bool Clear() = 0;

  ///
  /// Returns true if the current dictionary has a value for the given key.
  ///
  /*--cef()--*/
  virtual bool HasKey(const CefString& key) = 0;

  ///
  /// Reads all keys for this dictionary into the specified vector.
  ///
  /*--cef()--*/
  virtual bool GetKeys(KeyList& keys) = 0;

  ///
  /// Removes the value at the specified key. Returns true is the value was
  /// removed successfully.
  ///
  /*--cef()--*/
  virtual bool Remove(const CefString& key) = 0;

  ///
  /// Returns the value type for the specified key.
  ///
  /*--cef(default_retval=VTYPE_INVALID)--*/
  virtual CefValueType GetType(const CefString& key) = 0;

  ///
  /// Returns the value at the specified key. For simple types the returned
  /// value will copy existing data and modifications to the value will not
  /// modify this object. For complex types (binary, dictionary and list) the
  /// returned value will reference existing data and modifications to the value
  /// will modify this object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefValue> GetValue(const CefString& key) = 0;

  ///
  /// Returns the value at the specified key as type bool.
  ///
  /*--cef()--*/
  virtual bool GetBool(const CefString& key) = 0;

  ///
  /// Returns the value at the specified key as type int.
  ///
  /*--cef()--*/
  virtual int GetInt(const CefString& key) = 0;

  ///
  /// Returns the value at the specified key as type double.
  ///
  /*--cef()--*/
  virtual double GetDouble(const CefString& key) = 0;

  ///
  /// Returns the value at the specified key as type string.
  ///
  /*--cef()--*/
  virtual CefString GetString(const CefString& key) = 0;

  ///
  /// Returns the value at the specified key as type binary. The returned
  /// value will reference existing data.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBinaryValue> GetBinary(const CefString& key) = 0;

  ///
  /// Returns the value at the specified key as type dictionary. The returned
  /// value will reference existing data and modifications to the value will
  /// modify this object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefDictionaryValue> GetDictionary(const CefString& key) = 0;

  ///
  /// Returns the value at the specified key as type list. The returned value
  /// will reference existing data and modifications to the value will modify
  /// this object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefListValue> GetList(const CefString& key) = 0;

  ///
  /// Sets the value at the specified key. Returns true if the value was set
  /// successfully. If |value| represents simple data then the underlying data
  /// will be copied and modifications to |value| will not modify this object.
  /// If |value| represents complex data (binary, dictionary or list) then the
  /// underlying data will be referenced and modifications to |value| will
  /// modify this object.
  ///
  /*--cef()--*/
  virtual bool SetValue(const CefString& key, CefRefPtr<CefValue> value) = 0;

  ///
  /// Sets the value at the specified key as type null. Returns true if the
  /// value was set successfully.
  ///
  /*--cef()--*/
  virtual bool SetNull(const CefString& key) = 0;

  ///
  /// Sets the value at the specified key as type bool. Returns true if the
  /// value was set successfully.
  ///
  /*--cef()--*/
  virtual bool SetBool(const CefString& key, bool value) = 0;

  ///
  /// Sets the value at the specified key as type int. Returns true if the
  /// value was set successfully.
  ///
  /*--cef()--*/
  virtual bool SetInt(const CefString& key, int value) = 0;

  ///
  /// Sets the value at the specified key as type double. Returns true if the
  /// value was set successfully.
  ///
  /*--cef()--*/
  virtual bool SetDouble(const CefString& key, double value) = 0;

  ///
  /// Sets the value at the specified key as type string. Returns true if the
  /// value was set successfully.
  ///
  /*--cef(optional_param=value)--*/
  virtual bool SetString(const CefString& key, const CefString& value) = 0;

  ///
  /// Sets the value at the specified key as type binary. Returns true if the
  /// value was set successfully. If |value| is currently owned by another
  /// object then the value will be copied and the |value| reference will not
  /// change. Otherwise, ownership will be transferred to this object and the
  /// |value| reference will be invalidated.
  ///
  /*--cef()--*/
  virtual bool SetBinary(const CefString& key,
                         CefRefPtr<CefBinaryValue> value) = 0;

  ///
  /// Sets the value at the specified key as type dict. Returns true if the
  /// value was set successfully. If |value| is currently owned by another
  /// object then the value will be copied and the |value| reference will not
  /// change. Otherwise, ownership will be transferred to this object and the
  /// |value| reference will be invalidated.
  ///
  /*--cef()--*/
  virtual bool SetDictionary(const CefString& key,
                             CefRefPtr<CefDictionaryValue> value) = 0;

  ///
  /// Sets the value at the specified key as type list. Returns true if the
  /// value was set successfully. If |value| is currently owned by another
  /// object then the value will be copied and the |value| reference will not
  /// change. Otherwise, ownership will be transferred to this object and the
  /// |value| reference will be invalidated.
  ///
  /*--cef()--*/
  virtual bool SetList(const CefString& key, CefRefPtr<CefListValue> value) = 0;
};

///
/// Class representing a list value. Can be used on any process and thread.
///
/*--cef(source=library)--*/
class CefListValue : public virtual CefBaseRefCounted {
 public:
  ///
  /// Creates a new object that is not owned by any other object.
  ///
  /*--cef()--*/
  static CefRefPtr<CefListValue> Create();

  ///
  /// Returns true if this object is valid. This object may become invalid if
  /// the underlying data is owned by another object (e.g. list or dictionary)
  /// and that other object is then modified or destroyed. Do not call any other
  /// methods if this method returns false.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns true if this object is currently owned by another object.
  ///
  /*--cef()--*/
  virtual bool IsOwned() = 0;

  ///
  /// Returns true if the values of this object are read-only. Some APIs may
  /// expose read-only objects.
  ///
  /*--cef()--*/
  virtual bool IsReadOnly() = 0;

  ///
  /// Returns true if this object and |that| object have the same underlying
  /// data. If true modifications to this object will also affect |that| object
  /// and vice-versa.
  ///
  /*--cef()--*/
  virtual bool IsSame(CefRefPtr<CefListValue> that) = 0;

  ///
  /// Returns true if this object and |that| object have an equivalent
  /// underlying value but are not necessarily the same object.
  ///
  /*--cef()--*/
  virtual bool IsEqual(CefRefPtr<CefListValue> that) = 0;

  ///
  /// Returns a writable copy of this object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefListValue> Copy() = 0;

  ///
  /// Sets the number of values. If the number of values is expanded all
  /// new value slots will default to type null. Returns true on success.
  ///
  /*--cef()--*/
  virtual bool SetSize(size_t size) = 0;

  ///
  /// Returns the number of values.
  ///
  /*--cef()--*/
  virtual size_t GetSize() = 0;

  ///
  /// Removes all values. Returns true on success.
  ///
  /*--cef()--*/
  virtual bool Clear() = 0;

  ///
  /// Removes the value at the specified index.
  ///
  /*--cef()--*/
  virtual bool Remove(size_t index) = 0;

  ///
  /// Returns the value type at the specified index.
  ///
  /*--cef(default_retval=VTYPE_INVALID)--*/
  virtual CefValueType GetType(size_t index) = 0;

  ///
  /// Returns the value at the specified index. For simple types the returned
  /// value will copy existing data and modifications to the value will not
  /// modify this object. For complex types (binary, dictionary and list) the
  /// returned value will reference existing data and modifications to the value
  /// will modify this object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefValue> GetValue(size_t index) = 0;

  ///
  /// Returns the value at the specified index as type bool.
  ///
  /*--cef()--*/
  virtual bool GetBool(size_t index) = 0;

  ///
  /// Returns the value at the specified index as type int.
  ///
  /*--cef()--*/
  virtual int GetInt(size_t index) = 0;

  ///
  /// Returns the value at the specified index as type double.
  ///
  /*--cef()--*/
  virtual double GetDouble(size_t index) = 0;

  ///
  /// Returns the value at the specified index as type string.
  ///
  /*--cef()--*/
  virtual CefString GetString(size_t index) = 0;

  ///
  /// Returns the value at the specified index as type binary. The returned
  /// value will reference existing data.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBinaryValue> GetBinary(size_t index) = 0;

  ///
  /// Returns the value at the specified index as type dictionary. The returned
  /// value will reference existing data and modifications to the value will
  /// modify this object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefDictionaryValue> GetDictionary(size_t index) = 0;

  ///
  /// Returns the value at the specified index as type list. The returned
  /// value will reference existing data and modifications to the value will
  /// modify this object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefListValue> GetList(size_t index) = 0;

  ///
  /// Sets the value at the specified index. Returns true if the value was set
  /// successfully. If |value| represents simple data then the underlying data
  /// will be copied and modifications to |value| will not modify this object.
  /// If |value| represents complex data (binary, dictionary or list) then the
  /// underlying data will be referenced and modifications to |value| will
  /// modify this object.
  ///
  /*--cef()--*/
  virtual bool SetValue(size_t index, CefRefPtr<CefValue> value) = 0;

  ///
  /// Sets the value at the specified index as type null. Returns true if the
  /// value was set successfully.
  ///
  /*--cef()--*/
  virtual bool SetNull(size_t index) = 0;

  ///
  /// Sets the value at the specified index as type bool. Returns true if the
  /// value was set successfully.
  ///
  /*--cef()--*/
  virtual bool SetBool(size_t index, bool value) = 0;

  ///
  /// Sets the value at the specified index as type int. Returns true if the
  /// value was set successfully.
  ///
  /*--cef()--*/
  virtual bool SetInt(size_t index, int value) = 0;

  ///
  /// Sets the value at the specified index as type double. Returns true if the
  /// value was set successfully.
  ///
  /*--cef()--*/
  virtual bool SetDouble(size_t index, double value) = 0;

  ///
  /// Sets the value at the specified index as type string. Returns true if the
  /// value was set successfully.
  ///
  /*--cef(optional_param=value)--*/
  virtual bool SetString(size_t index, const CefString& value) = 0;

  ///
  /// Sets the value at the specified index as type binary. Returns true if the
  /// value was set successfully. If |value| is currently owned by another
  /// object then the value will be copied and the |value| reference will not
  /// change. Otherwise, ownership will be transferred to this object and the
  /// |value| reference will be invalidated.
  ///
  /*--cef()--*/
  virtual bool SetBinary(size_t index, CefRefPtr<CefBinaryValue> value) = 0;

  ///
  /// Sets the value at the specified index as type dict. Returns true if the
  /// value was set successfully. If |value| is currently owned by another
  /// object then the value will be copied and the |value| reference will not
  /// change. Otherwise, ownership will be transferred to this object and the
  /// |value| reference will be invalidated.
  ///
  /*--cef()--*/
  virtual bool SetDictionary(size_t index,
                             CefRefPtr<CefDictionaryValue> value) = 0;

  ///
  /// Sets the value at the specified index as type list. Returns true if the
  /// value was set successfully. If |value| is currently owned by another
  /// object then the value will be copied and the |value| reference will not
  /// change. Otherwise, ownership will be transferred to this object and the
  /// |value| reference will be invalidated.
  ///
  /*--cef()--*/
  virtual bool SetList(size_t index, CefRefPtr<CefListValue> value) = 0;
};

#endif  // CEF_INCLUDE_CEF_VALUES_H_
