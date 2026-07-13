// Copyright (c) 2013 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_V8_H_
#define CEF_INCLUDE_CEF_V8_H_
#pragma once

#include <vector>

#include "include/cef_base.h"
#include "include/cef_browser.h"
#include "include/cef_frame.h"
#include "include/cef_task.h"

class CefV8BackingStore;
class CefV8Exception;
class CefV8Handler;
class CefV8StackFrame;
class CefV8Value;

///
/// Register a new V8 extension with the specified JavaScript extension code and
/// handler. Functions implemented by the handler are prototyped using the
/// keyword 'native'. The calling of a native function is restricted to the
/// scope in which the prototype of the native function is defined. This
/// function may only be called on the render process main thread.
///
/// Example JavaScript extension code:
/// <pre>
///   // create the 'example' global object if it doesn't already exist.
///   if (!example)
///     example = {};
///   // create the 'example.test' global object if it doesn't already exist.
///   if (!example.test)
///     example.test = {};
///   (function() {
///     // Define the function 'example.test.myfunction'.
///     example.test.myfunction = function() {
///       // Call CefV8Handler::Execute() with the function name 'MyFunction'
///       // and no arguments.
///       native function MyFunction();
///       return MyFunction();
///     };
///     // Define the getter function for parameter 'example.test.myparam'.
///     example.test.__defineGetter__('myparam', function() {
///       // Call CefV8Handler::Execute() with the function name 'GetMyParam'
///       // and no arguments.
///       native function GetMyParam();
///       return GetMyParam();
///     });
///     // Define the setter function for parameter 'example.test.myparam'.
///     example.test.__defineSetter__('myparam', function(b) {
///       // Call CefV8Handler::Execute() with the function name 'SetMyParam'
///       // and a single argument.
///       native function SetMyParam();
///       if(b) SetMyParam(b);
///     });
///
///     // Extension definitions can also contain normal JavaScript variables
///     // and functions.
///     var myint = 0;
///     example.test.increment = function() {
///       myint += 1;
///       return myint;
///     };
///   })();
/// </pre>
///
/// Example usage in the page:
/// <pre>
///   // Call the function.
///   example.test.myfunction();
///   // Set the parameter.
///   example.test.myparam = value;
///   // Get the parameter.
///   value = example.test.myparam;
///   // Call another function.
///   example.test.increment();
/// </pre>
///
/*--cef(optional_param=handler)--*/
bool CefRegisterExtension(const CefString& extension_name,
                          const CefString& javascript_code,
                          CefRefPtr<CefV8Handler> handler);

///
/// Class representing a V8 context handle. V8 handles can only be accessed from
/// the thread on which they are created. Valid threads for creating a V8 handle
/// include the render process main thread (TID_RENDERER) and WebWorker threads.
/// A task runner for posting tasks on the associated thread can be retrieved
/// via the CefV8Context::GetTaskRunner() method.
///
/*--cef(source=library,no_debugct_check)--*/
class CefV8Context : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns the current (top) context object in the V8 context stack.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8Context> GetCurrentContext();

  ///
  /// Returns the entered (bottom) context object in the V8 context stack.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8Context> GetEnteredContext();

  ///
  /// Returns true if V8 is currently inside a context.
  ///
  /*--cef()--*/
  static bool InContext();

  ///
  /// Returns the task runner associated with this context. V8 handles can only
  /// be accessed from the thread on which they are created. This method can be
  /// called on any render process thread.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefTaskRunner> GetTaskRunner() = 0;

  ///
  /// Returns true if the underlying handle is valid and it can be accessed on
  /// the current thread. Do not call any other methods if this method returns
  /// false.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns the browser for this context. This method will return an empty
  /// reference for WebWorker contexts.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBrowser> GetBrowser() = 0;

  ///
  /// Returns the frame for this context. This method will return an empty
  /// reference for WebWorker contexts.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefFrame> GetFrame() = 0;

  ///
  /// Returns the global object for this context. The context must be entered
  /// before calling this method.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefV8Value> GetGlobal() = 0;

  ///
  /// Enter this context. A context must be explicitly entered before creating a
  /// V8 Object, Array, Function or Date asynchronously. Exit() must be called
  /// the same number of times as Enter() before releasing this context. V8
  /// objects belong to the context in which they are created. Returns true if
  /// the scope was entered successfully.
  ///
  /*--cef()--*/
  virtual bool Enter() = 0;

  ///
  /// Exit this context. Call this method only after calling Enter(). Returns
  /// true if the scope was exited successfully.
  ///
  /*--cef()--*/
  virtual bool Exit() = 0;

  ///
  /// Returns true if this object is pointing to the same handle as |that|
  /// object.
  ///
  /*--cef()--*/
  virtual bool IsSame(CefRefPtr<CefV8Context> that) = 0;

  ///
  /// Execute a string of JavaScript code in this V8 context. The |script_url|
  /// parameter is the URL where the script in question can be found, if any.
  /// The |start_line| parameter is the base line number to use for error
  /// reporting. On success |retval| will be set to the return value, if any,
  /// and the function will return true. On failure |exception| will be set to
  /// the exception, if any, and the function will return false.
  ///
  /*--cef(optional_param=script_url)--*/
  virtual bool Eval(const CefString& code,
                    const CefString& script_url,
                    int start_line,
                    CefRefPtr<CefV8Value>& retval,
                    CefRefPtr<CefV8Exception>& exception) = 0;
};

typedef std::vector<CefRefPtr<CefV8Value>> CefV8ValueList;

///
/// Interface that should be implemented to handle V8 function calls. The
/// methods of this class will be called on the thread associated with the V8
/// function.
///
/*--cef(source=client,no_debugct_check)--*/
class CefV8Handler : public virtual CefBaseRefCounted {
 public:
  ///
  /// Handle execution of the function identified by |name|. |object| is the
  /// receiver ('this' object) of the function. |arguments| is the list of
  /// arguments passed to the function. If execution succeeds set |retval| to
  /// the function return value. If execution fails set |exception| to the
  /// exception that will be thrown. Return true if execution was handled.
  ///
  /*--cef()--*/
  virtual bool Execute(const CefString& name,
                       CefRefPtr<CefV8Value> object,
                       const CefV8ValueList& arguments,
                       CefRefPtr<CefV8Value>& retval,
                       CefString& exception) = 0;
};

///
/// Interface that should be implemented to handle V8 accessor calls. Accessor
/// identifiers are registered by calling CefV8Value::SetValue(). The methods
/// of this class will be called on the thread associated with the V8 accessor.
///
/*--cef(source=client,no_debugct_check)--*/
class CefV8Accessor : public virtual CefBaseRefCounted {
 public:
  ///
  /// Handle retrieval the accessor value identified by |name|. |object| is the
  /// receiver ('this' object) of the accessor. If retrieval succeeds set
  /// |retval| to the return value. If retrieval fails set |exception| to the
  /// exception that will be thrown. Return true if accessor retrieval was
  /// handled.
  ///
  /*--cef()--*/
  virtual bool Get(const CefString& name,
                   const CefRefPtr<CefV8Value> object,
                   CefRefPtr<CefV8Value>& retval,
                   CefString& exception) = 0;

  ///
  /// Handle assignment of the accessor value identified by |name|. |object| is
  /// the receiver ('this' object) of the accessor. |value| is the new value
  /// being assigned to the accessor. If assignment fails set |exception| to the
  /// exception that will be thrown. Return true if accessor assignment was
  /// handled.
  ///
  /*--cef()--*/
  virtual bool Set(const CefString& name,
                   const CefRefPtr<CefV8Value> object,
                   const CefRefPtr<CefV8Value> value,
                   CefString& exception) = 0;
};

///
/// Interface that should be implemented to handle V8 interceptor calls. The
/// methods of this class will be called on the thread associated with the V8
/// interceptor. Interceptor's named property handlers (with first argument of
/// type CefString) are called when object is indexed by string. Indexed
/// property handlers (with first argument of type int) are called when object
/// is indexed by integer.
///
/*--cef(source=client,no_debugct_check)--*/
class CefV8Interceptor : public virtual CefBaseRefCounted {
 public:
  ///
  /// Handle retrieval of the interceptor value identified by |name|. |object|
  /// is the receiver ('this' object) of the interceptor. If retrieval succeeds,
  /// set |retval| to the return value. If the requested value does not exist,
  /// don't set either |retval| or |exception|. If retrieval fails, set
  /// |exception| to the exception that will be thrown. If the property has an
  /// associated accessor, it will be called only if you don't set |retval|.
  /// Return true if interceptor retrieval was handled, false otherwise.
  ///
  /*--cef(capi_name=get_byname)--*/
  virtual bool Get(const CefString& name,
                   const CefRefPtr<CefV8Value> object,
                   CefRefPtr<CefV8Value>& retval,
                   CefString& exception) = 0;

  ///
  /// Handle retrieval of the interceptor value identified by |index|. |object|
  /// is the receiver ('this' object) of the interceptor. If retrieval succeeds,
  /// set |retval| to the return value. If the requested value does not exist,
  /// don't set either |retval| or |exception|. If retrieval fails, set
  /// |exception| to the exception that will be thrown.
  /// Return true if interceptor retrieval was handled, false otherwise.
  ///
  /*--cef(capi_name=get_byindex,index_param=index)--*/
  virtual bool Get(int index,
                   const CefRefPtr<CefV8Value> object,
                   CefRefPtr<CefV8Value>& retval,
                   CefString& exception) = 0;

  ///
  /// Handle assignment of the interceptor value identified by |name|. |object|
  /// is the receiver ('this' object) of the interceptor. |value| is the new
  /// value being assigned to the interceptor. If assignment fails, set
  /// |exception| to the exception that will be thrown. This setter will always
  /// be called, even when the property has an associated accessor.
  /// Return true if interceptor assignment was handled, false otherwise.
  ///
  /*--cef(capi_name=set_byname)--*/
  virtual bool Set(const CefString& name,
                   const CefRefPtr<CefV8Value> object,
                   const CefRefPtr<CefV8Value> value,
                   CefString& exception) = 0;

  ///
  /// Handle assignment of the interceptor value identified by |index|. |object|
  /// is the receiver ('this' object) of the interceptor. |value| is the new
  /// value being assigned to the interceptor. If assignment fails, set
  /// |exception| to the exception that will be thrown.
  /// Return true if interceptor assignment was handled, false otherwise.
  ///
  /*--cef(capi_name=set_byindex,index_param=index)--*/
  virtual bool Set(int index,
                   const CefRefPtr<CefV8Value> object,
                   const CefRefPtr<CefV8Value> value,
                   CefString& exception) = 0;
};

///
/// Class representing a V8 exception. The methods of this class may be called
/// on any render process thread.
///
/*--cef(source=library,no_debugct_check)--*/
class CefV8Exception : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns the exception message.
  ///
  /*--cef()--*/
  virtual CefString GetMessage() = 0;

  ///
  /// Returns the line of source code that the exception occurred within.
  ///
  /*--cef()--*/
  virtual CefString GetSourceLine() = 0;

  ///
  /// Returns the resource name for the script from where the function causing
  /// the error originates.
  ///
  /*--cef()--*/
  virtual CefString GetScriptResourceName() = 0;

  ///
  /// Returns the 1-based number of the line where the error occurred or 0 if
  /// the line number is unknown.
  ///
  /*--cef()--*/
  virtual int GetLineNumber() = 0;

  ///
  /// Returns the index within the script of the first character where the error
  /// occurred.
  ///
  /*--cef()--*/
  virtual int GetStartPosition() = 0;

  ///
  /// Returns the index within the script of the last character where the error
  /// occurred.
  ///
  /*--cef()--*/
  virtual int GetEndPosition() = 0;

  ///
  /// Returns the index within the line of the first character where the error
  /// occurred.
  ///
  /*--cef()--*/
  virtual int GetStartColumn() = 0;

  ///
  /// Returns the index within the line of the last character where the error
  /// occurred.
  ///
  /*--cef()--*/
  virtual int GetEndColumn() = 0;
};

///
/// Callback interface that is passed to CefV8Value::CreateArrayBuffer.
///
/*--cef(source=client,no_debugct_check)--*/
class CefV8ArrayBufferReleaseCallback : public virtual CefBaseRefCounted {
 public:
  ///
  /// Called to release |buffer| when the ArrayBuffer JS object is garbage
  /// collected. |buffer| is the value that was passed to CreateArrayBuffer
  /// along with this object.
  ///
  /*--cef()--*/
  virtual void ReleaseBuffer(void* buffer) = 0;
};

#if CEF_API_ADDED(14600)
///
/// Class representing a V8 ArrayBuffer backing store. The backing store holds
/// the memory that backs an ArrayBuffer. It must be created on a thread with a
/// valid V8 isolate (renderer main thread or WebWorker thread). Once created,
/// the Data() pointer can be safely read/written from any thread. This allows
/// expensive operations like memcpy to be performed on a background thread
/// before creating the ArrayBuffer on the V8 thread.
///
/// The backing store is consumed when passed to
/// CefV8Value::CreateArrayBufferFromBackingStore(), after which IsValid()
/// returns false.
///
/*--cef(source=library,no_debugct_check,added=14600)--*/
class CefV8BackingStore : public virtual CefBaseRefCounted {
 public:
  ///
  /// Create a new backing store with allocated memory of |byte_length| bytes.
  /// The memory is uninitialized. This method must be called on a thread with a
  /// valid V8 isolate. The returned object can safely be passed to other
  /// threads. Returns nullptr on failure.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8BackingStore> Create(size_t byte_length);

  ///
  /// Returns a pointer to the allocated memory, or nullptr if the backing
  /// store has been consumed or is otherwise invalid. The pointer is safe to
  /// read/write from any thread. The caller must ensure all writes are complete
  /// before passing this object to CreateArrayBufferFromBackingStore().
  /// Pointers obtained from this method should not be retained after calling
  /// CreateArrayBufferFromBackingStore(), as the memory will then be owned by
  /// the ArrayBuffer and subject to V8 garbage collection.
  ///
  /*--cef()--*/
  virtual void* Data() = 0;

  ///
  /// Returns the size of the allocated memory in bytes, or 0 if the backing
  /// store has been consumed.
  ///
  /*--cef()--*/
  virtual size_t ByteLength() = 0;

  ///
  /// Returns true if this backing store has not yet been consumed by
  /// CreateArrayBufferFromBackingStore().
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;
};
#endif

///
/// Class representing a V8 value handle. V8 handles can only be accessed from
/// the thread on which they are created. Valid threads for creating a V8 handle
/// include the render process main thread (TID_RENDERER) and WebWorker threads.
/// A task runner for posting tasks on the associated thread can be retrieved
/// via the CefV8Context::GetTaskRunner() method.
///
/*--cef(source=library,no_debugct_check)--*/
class CefV8Value : public virtual CefBaseRefCounted {
 public:
  typedef cef_v8_propertyattribute_t PropertyAttribute;

  ///
  /// Create a new CefV8Value object of type undefined.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8Value> CreateUndefined();

  ///
  /// Create a new CefV8Value object of type null.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8Value> CreateNull();

  ///
  /// Create a new CefV8Value object of type bool.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8Value> CreateBool(bool value);

  ///
  /// Create a new CefV8Value object of type int.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8Value> CreateInt(int32_t value);

  ///
  /// Create a new CefV8Value object of type unsigned int.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8Value> CreateUInt(uint32_t value);

  ///
  /// Create a new CefV8Value object of type double.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8Value> CreateDouble(double value);

  ///
  /// Create a new CefV8Value object of type Date. This method should only be
  /// called from within the scope of a CefRenderProcessHandler, CefV8Handler or
  /// CefV8Accessor callback, or in combination with calling Enter() and Exit()
  /// on a stored CefV8Context reference.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8Value> CreateDate(CefBaseTime date);

  ///
  /// Create a new CefV8Value object of type string.
  ///
  /*--cef(optional_param=value)--*/
  static CefRefPtr<CefV8Value> CreateString(const CefString& value);

  ///
  /// Create a new CefV8Value object of type object with optional accessor
  /// and/or interceptor. This method should only be called from within the
  /// scope of a CefRenderProcessHandler, CefV8Handler or CefV8Accessor
  /// callback, or in combination with calling Enter() and Exit() on a stored
  /// CefV8Context reference.
  ///
  /*--cef(optional_param=accessor, optional_param=interceptor)--*/
  static CefRefPtr<CefV8Value> CreateObject(
      CefRefPtr<CefV8Accessor> accessor,
      CefRefPtr<CefV8Interceptor> interceptor);

  ///
  /// Create a new CefV8Value object of type array with the specified |length|.
  /// If |length| is negative the returned array will have length 0. This method
  /// should only be called from within the scope of a CefRenderProcessHandler,
  /// CefV8Handler or CefV8Accessor callback, or in combination with calling
  /// Enter() and Exit() on a stored CefV8Context reference.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8Value> CreateArray(int length);

  ///
  /// Create a new CefV8Value object of type ArrayBuffer which wraps the
  /// provided |buffer| of size |length| bytes. The ArrayBuffer is externalized,
  /// meaning that it does not own |buffer|. The caller is responsible for
  /// freeing |buffer| when requested via a call to
  /// CefV8ArrayBufferReleaseCallback::ReleaseBuffer. This method should only
  /// be called from within the scope of a CefRenderProcessHandler, CefV8Handler
  /// or CefV8Accessor callback, or in combination with calling Enter() and
  /// Exit() on a stored CefV8Context reference.
  ///
  /// NOTE: Always returns nullptr when V8 sandbox is enabled.
  ///
  /*--cef(optional_param=buffer)--*/
  static CefRefPtr<CefV8Value> CreateArrayBuffer(
      void* buffer,
      size_t length,
      CefRefPtr<CefV8ArrayBufferReleaseCallback> release_callback);

  ///
  /// Create a new CefV8Value object of type ArrayBuffer which copies the
  /// provided |buffer| of size |length| bytes.
  /// This method should only be called from within the scope of a
  /// CefRenderProcessHandler, CefV8Handler or CefV8Accessor callback, or in
  /// combination with calling Enter() and Exit() on a stored CefV8Context
  /// reference.
  ///
  /*--cef(optional_param=buffer)--*/
  static CefRefPtr<CefV8Value> CreateArrayBufferWithCopy(void* buffer,
                                                         size_t length);

#if CEF_API_ADDED(14600)
  ///
  /// Create a new CefV8Value object of type ArrayBuffer from a backing store
  /// previously created with CefV8BackingStore::Create(). This is a zero-copy
  /// operation — the ArrayBuffer uses the memory already allocated by the
  /// backing store. The backing store is consumed and becomes invalid after
  /// this call. This method should only be called from within the scope of a
  /// CefRenderProcessHandler, CefV8Handler or CefV8Accessor callback, or in
  /// combination with calling Enter() and Exit() on a stored CefV8Context
  /// reference.
  ///
  /*--cef(added=14600)--*/
  static CefRefPtr<CefV8Value> CreateArrayBufferFromBackingStore(
      CefRefPtr<CefV8BackingStore> backing_store);
#endif

  ///
  /// Create a new CefV8Value object of type function. This method should only
  /// be called from within the scope of a CefRenderProcessHandler, CefV8Handler
  /// or CefV8Accessor callback, or in combination with calling Enter() and
  /// Exit() on a stored CefV8Context reference.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8Value> CreateFunction(const CefString& name,
                                              CefRefPtr<CefV8Handler> handler);

  ///
  /// Create a new CefV8Value object of type Promise. This method should only be
  /// called from within the scope of a CefRenderProcessHandler, CefV8Handler or
  /// CefV8Accessor callback, or in combination with calling Enter() and Exit()
  /// on a stored CefV8Context reference.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8Value> CreatePromise();

  ///
  /// Returns true if the underlying handle is valid and it can be accessed on
  /// the current thread. Do not call any other methods if this method returns
  /// false.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// True if the value type is undefined.
  ///
  /*--cef()--*/
  virtual bool IsUndefined() = 0;

  ///
  /// True if the value type is null.
  ///
  /*--cef()--*/
  virtual bool IsNull() = 0;

  ///
  /// True if the value type is bool.
  ///
  /*--cef()--*/
  virtual bool IsBool() = 0;

  ///
  /// True if the value type is int.
  ///
  /*--cef()--*/
  virtual bool IsInt() = 0;

  ///
  /// True if the value type is unsigned int.
  ///
  /*--cef()--*/
  virtual bool IsUInt() = 0;

  ///
  /// True if the value type is double.
  ///
  /*--cef()--*/
  virtual bool IsDouble() = 0;

  ///
  /// True if the value type is Date.
  ///
  /*--cef()--*/
  virtual bool IsDate() = 0;

  ///
  /// True if the value type is string.
  ///
  /*--cef()--*/
  virtual bool IsString() = 0;

  ///
  /// True if the value type is object.
  ///
  /*--cef()--*/
  virtual bool IsObject() = 0;

  ///
  /// True if the value type is array.
  ///
  /*--cef()--*/
  virtual bool IsArray() = 0;

  ///
  /// True if the value type is an ArrayBuffer.
  ///
  /*--cef()--*/
  virtual bool IsArrayBuffer() = 0;

  ///
  /// True if the value type is function.
  ///
  /*--cef()--*/
  virtual bool IsFunction() = 0;

  ///
  /// True if the value type is a Promise.
  ///
  /*--cef()--*/
  virtual bool IsPromise() = 0;

  ///
  /// Returns true if this object is pointing to the same handle as |that|
  /// object.
  ///
  /*--cef()--*/
  virtual bool IsSame(CefRefPtr<CefV8Value> that) = 0;

  ///
  /// Return a bool value.
  ///
  /*--cef()--*/
  virtual bool GetBoolValue() = 0;

  ///
  /// Return an int value.
  ///
  /*--cef()--*/
  virtual int32_t GetIntValue() = 0;

  ///
  /// Return an unsigned int value.
  ///
  /*--cef()--*/
  virtual uint32_t GetUIntValue() = 0;

  ///
  /// Return a double value.
  ///
  /*--cef()--*/
  virtual double GetDoubleValue() = 0;

  ///
  /// Return a Date value.
  ///
  /*--cef()--*/
  virtual CefBaseTime GetDateValue() = 0;

  ///
  /// Return a string value.
  ///
  /*--cef()--*/
  virtual CefString GetStringValue() = 0;

  /// OBJECT METHODS - These methods are only available on objects. Arrays and
  /// functions are also objects. String- and integer-based keys can be used
  /// interchangably with the framework converting between them as necessary.

  ///
  /// Returns true if this is a user created object.
  ///
  /*--cef()--*/
  virtual bool IsUserCreated() = 0;

  ///
  /// Returns true if the last method call resulted in an exception. This
  /// attribute exists only in the scope of the current CEF value object.
  ///
  /*--cef()--*/
  virtual bool HasException() = 0;

  ///
  /// Returns the exception resulting from the last method call. This attribute
  /// exists only in the scope of the current CEF value object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefV8Exception> GetException() = 0;

  ///
  /// Clears the last exception and returns true on success.
  ///
  /*--cef()--*/
  virtual bool ClearException() = 0;

  ///
  /// Returns true if this object will re-throw future exceptions. This
  /// attribute exists only in the scope of the current CEF value object.
  ///
  /*--cef()--*/
  virtual bool WillRethrowExceptions() = 0;

  ///
  /// Set whether this object will re-throw future exceptions. By default
  /// exceptions are not re-thrown. If a exception is re-thrown the current
  /// context should not be accessed again until after the exception has been
  /// caught and not re-thrown. Returns true on success. This attribute exists
  /// only in the scope of the current CEF value object.
  ///
  /*--cef()--*/
  virtual bool SetRethrowExceptions(bool rethrow) = 0;

  ///
  /// Returns true if the object has a value with the specified identifier.
  ///
  /*--cef(capi_name=has_value_bykey,optional_param=key)--*/
  virtual bool HasValue(const CefString& key) = 0;

  ///
  /// Returns true if the object has a value with the specified identifier.
  ///
  /*--cef(capi_name=has_value_byindex,index_param=index)--*/
  virtual bool HasValue(int index) = 0;

  ///
  /// Deletes the value with the specified identifier and returns true on
  /// success. Returns false if this method is called incorrectly or an
  /// exception is thrown. For read-only and don't-delete values this method
  /// will return true even though deletion failed.
  ///
  /*--cef(capi_name=delete_value_bykey,optional_param=key)--*/
  virtual bool DeleteValue(const CefString& key) = 0;

  ///
  /// Deletes the value with the specified identifier and returns true on
  /// success. Returns false if this method is called incorrectly, deletion
  /// fails or an exception is thrown. For read-only and don't-delete values
  /// this method will return true even though deletion failed.
  ///
  /*--cef(capi_name=delete_value_byindex,index_param=index)--*/
  virtual bool DeleteValue(int index) = 0;

  ///
  /// Returns the value with the specified identifier on success. Returns NULL
  /// if this method is called incorrectly or an exception is thrown.
  ///
  /*--cef(capi_name=get_value_bykey,optional_param=key)--*/
  virtual CefRefPtr<CefV8Value> GetValue(const CefString& key) = 0;

  ///
  /// Returns the value with the specified identifier on success. Returns NULL
  /// if this method is called incorrectly or an exception is thrown.
  ///
  /*--cef(capi_name=get_value_byindex,index_param=index)--*/
  virtual CefRefPtr<CefV8Value> GetValue(int index) = 0;

  ///
  /// Associates a value with the specified identifier and returns true on
  /// success. Returns false if this method is called incorrectly or an
  /// exception is thrown. For read-only values this method will return true
  /// even though assignment failed.
  ///
  /*--cef(capi_name=set_value_bykey,optional_param=key)--*/
  virtual bool SetValue(const CefString& key,
                        CefRefPtr<CefV8Value> value,
                        PropertyAttribute attribute) = 0;

  ///
  /// Associates a value with the specified identifier and returns true on
  /// success. Returns false if this method is called incorrectly or an
  /// exception is thrown. For read-only values this method will return true
  /// even though assignment failed.
  ///
  /*--cef(capi_name=set_value_byindex,index_param=index)--*/
  virtual bool SetValue(int index, CefRefPtr<CefV8Value> value) = 0;

  ///
  /// Registers an identifier and returns true on success. Access to the
  /// identifier will be forwarded to the CefV8Accessor instance passed to
  /// CefV8Value::CreateObject(). Returns false if this method is called
  /// incorrectly or an exception is thrown. For read-only values this method
  /// will return true even though assignment failed.
  ///
  /*--cef(capi_name=set_value_byaccessor,optional_param=key)--*/
  virtual bool SetValue(const CefString& key, PropertyAttribute attribute) = 0;

  ///
  /// Read the keys for the object's values into the specified vector. Integer-
  /// based keys will also be returned as strings.
  ///
  /*--cef()--*/
  virtual bool GetKeys(std::vector<CefString>& keys) = 0;

  ///
  /// Sets the user data for this object and returns true on success. Returns
  /// false if this method is called incorrectly. This method can only be called
  /// on user created objects.
  ///
  /*--cef(optional_param=user_data)--*/
  virtual bool SetUserData(CefRefPtr<CefBaseRefCounted> user_data) = 0;

  ///
  /// Returns the user data, if any, assigned to this object.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefBaseRefCounted> GetUserData() = 0;

  ///
  /// Returns the amount of externally allocated memory registered for the
  /// object.
  ///
  /*--cef()--*/
  virtual int GetExternallyAllocatedMemory() = 0;

  ///
  /// Adjusts the amount of registered external memory for the object. Used to
  /// give V8 an indication of the amount of externally allocated memory that is
  /// kept alive by JavaScript objects. V8 uses this information to decide when
  /// to perform global garbage collection. Each CefV8Value tracks the amount of
  /// external memory associated with it and automatically decreases the global
  /// total by the appropriate amount on its destruction. |change_in_bytes|
  /// specifies the number of bytes to adjust by. This method returns the number
  /// of bytes associated with the object after the adjustment. This method can
  /// only be called on user created objects.
  ///
  /*--cef()--*/
  virtual int AdjustExternallyAllocatedMemory(int change_in_bytes) = 0;

  // ARRAY METHODS - These methods are only available on arrays.

  ///
  /// Returns the number of elements in the array.
  ///
  /*--cef()--*/
  virtual int GetArrayLength() = 0;

  // ARRAY BUFFER METHODS - These methods are only available on ArrayBuffers.

  ///
  /// Returns the ReleaseCallback object associated with the ArrayBuffer or NULL
  /// if the ArrayBuffer was not created with CreateArrayBuffer.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefV8ArrayBufferReleaseCallback>
  GetArrayBufferReleaseCallback() = 0;

  ///
  /// Prevent the ArrayBuffer from using it's memory block by setting the length
  /// to zero. This operation cannot be undone. If the ArrayBuffer was created
  /// with CreateArrayBuffer then CefV8ArrayBufferReleaseCallback::ReleaseBuffer
  /// will be called to release the underlying buffer.
  ///
  /*--cef()--*/
  virtual bool NeuterArrayBuffer() = 0;

  ///
  /// Returns the length (in bytes) of the ArrayBuffer.
  ///
  /*--cef()--*/
  virtual size_t GetArrayBufferByteLength() = 0;

  ///
  /// Returns a pointer to the beginning of the memory block for this
  /// ArrayBuffer backing store. The returned pointer is valid as long as the
  /// CefV8Value is alive.
  ///
  /*--cef()--*/
  virtual void* GetArrayBufferData() = 0;

  // FUNCTION METHODS - These methods are only available on functions.

  ///
  /// Returns the function name.
  ///
  /*--cef()--*/
  virtual CefString GetFunctionName() = 0;

  ///
  /// Returns the function handler or NULL if not a CEF-created function.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefV8Handler> GetFunctionHandler() = 0;

  ///
  /// Execute the function using the current V8 context. This method should only
  /// be called from within the scope of a CefV8Handler or CefV8Accessor
  /// callback, or in combination with calling Enter() and Exit() on a stored
  /// CefV8Context reference. |object| is the receiver ('this' object) of the
  /// function. If |object| is empty the current context's global object will be
  /// used. |arguments| is the list of arguments that will be passed to the
  /// function. Returns the function return value on success. Returns NULL if
  /// this method is called incorrectly or an exception is thrown.
  ///
  /*--cef(optional_param=object)--*/
  virtual CefRefPtr<CefV8Value> ExecuteFunction(
      CefRefPtr<CefV8Value> object,
      const CefV8ValueList& arguments) = 0;

  ///
  /// Execute the function using the specified V8 context. |object| is the
  /// receiver ('this' object) of the function. If |object| is empty the
  /// specified context's global object will be used. |arguments| is the list of
  /// arguments that will be passed to the function. Returns the function return
  /// value on success. Returns NULL if this method is called incorrectly or an
  /// exception is thrown.
  ///
  /*--cef(optional_param=object)--*/
  virtual CefRefPtr<CefV8Value> ExecuteFunctionWithContext(
      CefRefPtr<CefV8Context> context,
      CefRefPtr<CefV8Value> object,
      const CefV8ValueList& arguments) = 0;

  // PROMISE METHODS - These methods are only available on Promises.

  ///
  /// Resolve the Promise using the current V8 context. This method should only
  /// be called from within the scope of a CefV8Handler or CefV8Accessor
  /// callback, or in combination with calling Enter() and Exit() on a stored
  /// CefV8Context reference. |arg| is the argument passed to the resolved
  /// promise. Returns true on success. Returns false if this method is called
  /// incorrectly or an exception is thrown.
  ///
  /*--cef(optional_param=arg)--*/
  virtual bool ResolvePromise(CefRefPtr<CefV8Value> arg) = 0;

  ///
  /// Reject the Promise using the current V8 context. This method should only
  /// be called from within the scope of a CefV8Handler or CefV8Accessor
  /// callback, or in combination with calling Enter() and Exit() on a stored
  /// CefV8Context reference. Returns true on success. Returns false if this
  /// method is called incorrectly or an exception is thrown.
  ///
  /*--cef()--*/
  virtual bool RejectPromise(const CefString& errorMsg) = 0;
};

///
/// Class representing a V8 stack trace handle. V8 handles can only be accessed
/// from the thread on which they are created. Valid threads for creating a V8
/// handle include the render process main thread (TID_RENDERER) and WebWorker
/// threads. A task runner for posting tasks on the associated thread can be
/// retrieved via the CefV8Context::GetTaskRunner() method.
///
/*--cef(source=library)--*/
class CefV8StackTrace : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns the stack trace for the currently active context. |frame_limit| is
  /// the maximum number of frames that will be captured.
  ///
  /*--cef()--*/
  static CefRefPtr<CefV8StackTrace> GetCurrent(int frame_limit);

  ///
  /// Returns true if the underlying handle is valid and it can be accessed on
  /// the current thread. Do not call any other methods if this method returns
  /// false.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns the number of stack frames.
  ///
  /*--cef()--*/
  virtual int GetFrameCount() = 0;

  ///
  /// Returns the stack frame at the specified 0-based index.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefV8StackFrame> GetFrame(int index) = 0;
};

///
/// Class representing a V8 stack frame handle. V8 handles can only be accessed
/// from the thread on which they are created. Valid threads for creating a V8
/// handle include the render process main thread (TID_RENDERER) and WebWorker
/// threads. A task runner for posting tasks on the associated thread can be
/// retrieved via the CefV8Context::GetTaskRunner() method.
///
/*--cef(source=library,no_debugct_check)--*/
class CefV8StackFrame : public virtual CefBaseRefCounted {
 public:
  ///
  /// Returns true if the underlying handle is valid and it can be accessed on
  /// the current thread. Do not call any other methods if this method returns
  /// false.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns the name of the resource script that contains the function.
  ///
  /*--cef()--*/
  virtual CefString GetScriptName() = 0;

  ///
  /// Returns the name of the resource script that contains the function or the
  /// sourceURL value if the script name is undefined and its source ends with
  /// a "//@ sourceURL=..." string.
  ///
  /*--cef()--*/
  virtual CefString GetScriptNameOrSourceURL() = 0;

  ///
  /// Returns the name of the function.
  ///
  /*--cef()--*/
  virtual CefString GetFunctionName() = 0;

  ///
  /// Returns the 1-based line number for the function call or 0 if unknown.
  ///
  /*--cef()--*/
  virtual int GetLineNumber() = 0;

  ///
  /// Returns the 1-based column offset on the line for the function call or 0
  /// if unknown.
  ///
  /*--cef()--*/
  virtual int GetColumn() = 0;

  ///
  /// Returns true if the function was compiled using eval().
  ///
  /*--cef()--*/
  virtual bool IsEval() = 0;

  ///
  /// Returns true if the function was called as a constructor via "new".
  ///
  /*--cef()--*/
  virtual bool IsConstructor() = 0;
};

#endif  // CEF_INCLUDE_CEF_V8_H_
