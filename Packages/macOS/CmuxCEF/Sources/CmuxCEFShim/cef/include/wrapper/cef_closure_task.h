// Copyright (c) 2014 Marshall A. Greenblatt. All rights reserved.
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
// The contents of this file are only available to applications that link
// against the libcef_dll_wrapper target.
//

#ifndef CEF_INCLUDE_WRAPPER_CEF_CLOSURE_TASK_H_
#define CEF_INCLUDE_WRAPPER_CEF_CLOSURE_TASK_H_
#pragma once

#include "include/base/cef_callback_forward.h"
#include "include/cef_task.h"

///
/// \file
/// Helpers for asynchronously executing a base::[Once|Repeating]Closure (bound
/// function or method) on a CEF thread. Creation of a
/// base::[Once|Repeating]Closure can be facilitated using
/// base::Bind[Once|Repeating]. See include/base/cef_callback.h for complete
/// usage instructions.
///
/// To use these helpers you should include this header and the header that
/// defines base::Bind[Once|Repeating].
///
/// <pre>
///   #include "include/base/cef_callback.h"
///   #include "include/wrapper/cef_closure_task.h"
/// </pre>
///
/// Example of executing a bound function:
///
/// <pre>
///   // Define a function.
///   void MyFunc(int arg) { /* do something with |arg| on the UI thread */ }
///
///   // Post a task that will execute MyFunc on the UI thread and pass an |arg|
///   // value of 5.
///   CefPostTask(TID_UI, base::BindOnce(&MyFunc, 5));
/// </pre>
///
/// Example of executing a bound method:
///
/// <pre>
///   // Define a class.
///   class MyClass : public CefBaseRefCounted {
///    public:
///     MyClass() {}
///     void MyMethod(int arg) { /* do something with |arg| on the UI thread */
///     }
///    private:
///     IMPLEMENT_REFCOUNTING(MyClass);
///   };
///
///   // Create an instance of MyClass.
///   CefRefPtr<MyClass> instance = new MyClass();
///
///   // Post a task that will execute MyClass::MyMethod on the UI thread and
///   // pass an |arg| value of 5. |instance| will be kept alive until after the
///   // task completes.
///   CefPostTask(TID_UI, base::BindOnce(&MyClass::MyMethod, instance, 5));
/// </pre>
///

///
/// Create a CefTask that wraps a base::[Once|Repeating]Closure. Can be used in
/// combination with CefTaskRunner.
///
CefRefPtr<CefTask> CefCreateClosureTask(base::OnceClosure closure);
CefRefPtr<CefTask> CefCreateClosureTask(const base::RepeatingClosure& closure);

///
/// Post a base::[Once|Repeating]Closure for execution on the specified thread.
///
bool CefPostTask(CefThreadId threadId, base::OnceClosure closure);
bool CefPostTask(CefThreadId threadId, const base::RepeatingClosure& closure);

///
/// Post a base::[Once|Repeating]Closure for delayed execution on the specified
/// thread.
///
bool CefPostDelayedTask(CefThreadId threadId,
                        base::OnceClosure closure,
                        int64_t delay_ms);
bool CefPostDelayedTask(CefThreadId threadId,
                        const base::RepeatingClosure& closure,
                        int64_t delay_ms);

#endif  // CEF_INCLUDE_WRAPPER_CEF_CLOSURE_TASK_H_
