// Copyright (c) 2014 Marshall A. Greenblatt. Portions copyright (c) 2012
// Google Inc. All rights reserved.
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

///
/// \file
/// Trace events are for tracking application performance and resource usage.
/// Macros are provided to track:
///    Begin and end of function calls
///    Counters
///
/// Events are issued against categories. Whereas LOG's categories are
/// statically defined, TRACE categories are created implicitly with a string.
/// For example: <pre>
///   TRACE_EVENT_INSTANT0("MY_SUBSYSTEM", "SomeImportantEvent")
/// </pre>
///
/// Events can be INSTANT, or can be pairs of BEGIN and END in the same scope:
/// <pre>
///   TRACE_EVENT_BEGIN0("MY_SUBSYSTEM", "SomethingCostly")
///   doSomethingCostly()
///   TRACE_EVENT_END0("MY_SUBSYSTEM", "SomethingCostly")
/// </pre>
/// Note: Our tools can't always determine the correct BEGIN/END pairs unless
/// these are used in the same scope. Use ASYNC_BEGIN/ASYNC_END macros if you
/// need them to be in separate scopes.
///
/// A common use case is to trace entire function scopes. This issues a trace
/// BEGIN and END automatically:
/// <pre>
///   void doSomethingCostly() {
///     TRACE_EVENT0("MY_SUBSYSTEM", "doSomethingCostly");
///     ...
///   }
/// </pre>
///
/// Additional parameters can be associated with an event:
/// <pre>
///   void doSomethingCostly2(int howMuch) {
///     TRACE_EVENT1("MY_SUBSYSTEM", "doSomethingCostly",
///         "howMuch", howMuch);
///     ...
///   }
/// </pre>
///
/// The trace system will automatically add to this information the current
/// process id, thread id, and a timestamp in microseconds.
///
/// To trace an asynchronous procedure such as an IPC send/receive, use
/// ASYNC_BEGIN and ASYNC_END:
/// <pre>
///   [single threaded sender code]
///     static int send_count = 0;
///     ++send_count;
///     TRACE_EVENT_ASYNC_BEGIN0("ipc", "message", send_count);
///     Send(new MyMessage(send_count));
///   [receive code]
///     void OnMyMessage(send_count) {
///       TRACE_EVENT_ASYNC_END0("ipc", "message", send_count);
///     }
/// </pre>
/// The third parameter is a unique ID to match ASYNC_BEGIN/ASYNC_END pairs.
/// ASYNC_BEGIN and ASYNC_END can occur on any thread of any traced process.
/// Pointers can be used for the ID parameter, and they will be mangled
/// internally so that the same pointer on two different processes will not
/// match. For example:
/// <pre>
///   class MyTracedClass {
///    public:
///     MyTracedClass() {
///       TRACE_EVENT_ASYNC_BEGIN0("category", "MyTracedClass", this);
///     }
///     ~MyTracedClass() {
///       TRACE_EVENT_ASYNC_END0("category", "MyTracedClass", this);
///     }
///   }
/// </pre>
///
/// The trace event also supports counters, which is a way to track a quantity
/// as it varies over time. Counters are created with the following macro:
/// <pre>
///   TRACE_COUNTER1("MY_SUBSYSTEM", "myCounter", g_myCounterValue);
/// </pre>
///
/// Counters are process-specific. The macro itself can be issued from any
/// thread, however.
///
/// Sometimes, you want to track two counters at once. You can do this with two
/// counter macros:
/// <pre>
///   TRACE_COUNTER1("MY_SUBSYSTEM", "myCounter0", g_myCounterValue[0]);
///   TRACE_COUNTER1("MY_SUBSYSTEM", "myCounter1", g_myCounterValue[1]);
/// </pre>
/// Or you can do it with a combined macro:
/// <pre>
///   TRACE_COUNTER2("MY_SUBSYSTEM", "myCounter",
///       "bytesPinned", g_myCounterValue[0],
///       "bytesAllocated", g_myCounterValue[1]);
/// </pre>
/// This indicates to the tracing UI that these counters should be displayed
/// in a single graph, as a summed area chart.
///
/// Since counters are in a global namespace, you may want to disembiguate with
/// a unique ID, by using the TRACE_COUNTER_ID* variations.
///
/// By default, trace collection is compiled in, but turned off at runtime.
/// Collecting trace data is the responsibility of the embedding application. In
/// CEF's case, calling BeginTracing will turn on tracing on all active
/// processes.
///
///
/// Memory scoping note:
/// Tracing copies the pointers, not the string content, of the strings passed
/// in for category, name, and arg_names.  Thus, the following code will cause
/// problems:
/// <pre>
///     char* str = strdup("impprtantName");
///     TRACE_EVENT_INSTANT0("SUBSYSTEM", str);  // BAD!
///     free(str);                   // Trace system now has dangling pointer
/// </pre>
///
///
/// Thread Safety:
/// All macros are thread safe and can be used from any process.
///

#ifndef CEF_INCLUDE_BASE_CEF_TRACE_EVENT_H_
#define CEF_INCLUDE_BASE_CEF_TRACE_EVENT_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
/// When building CEF include the Chromium header directly.
#include "base/trace_event/trace_event.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include "include/internal/cef_trace_event_internal.h"

///
/// Records a pair of begin and end events called "name" for the current
/// scope, with 0, 1 or 2 associated arguments. If the category is not
/// enabled, then this does nothing.
/// - category and name strings must have application lifetime (statics or
///   literals). They may not include " chars.
///
#define TRACE_EVENT0(category, name)                       \
  cef_trace_event_begin(category, name, NULL, 0, NULL, 0); \
  CEF_INTERNAL_TRACE_END_ON_SCOPE_CLOSE(category, name)
#define TRACE_EVENT1(category, name, arg1_name, arg1_val)              \
  cef_trace_event_begin(category, name, arg1_name, arg1_val, NULL, 0); \
  CEF_INTERNAL_TRACE_END_ON_SCOPE_CLOSE(category, name)
#define TRACE_EVENT2(category, name, arg1_name, arg1_val, arg2_name, arg2_val) \
  cef_trace_event_begin(category, name, arg1_name, arg1_val, arg2_name,        \
                        arg2_val);                                             \
  CEF_INTERNAL_TRACE_END_ON_SCOPE_CLOSE(category, name)

// Implementation detail: trace event macros create temporary variable names.
// These macros give each temporary variable a unique name based on the line
// number to prevent name collisions.
#define CEF_INTERNAL_TRACE_EVENT_UID3(a, b) cef_trace_event_unique_##a##b
#define CEF_INTERNAL_TRACE_EVENT_UID2(a, b) CEF_INTERNAL_TRACE_EVENT_UID3(a, b)
#define CEF_INTERNAL_TRACE_EVENT_UID(name_prefix) \
  CEF_INTERNAL_TRACE_EVENT_UID2(name_prefix, __LINE__)

// Implementation detail: internal macro to end end event when the scope ends.
#define CEF_INTERNAL_TRACE_END_ON_SCOPE_CLOSE(category, name)            \
  cef_trace_event::CefTraceEndOnScopeClose CEF_INTERNAL_TRACE_EVENT_UID( \
      profileScope)(category, name)

///
/// Records a single event called "name" immediately, with 0, 1 or 2
/// associated arguments. If the category is not enabled, then this
/// does nothing.
/// - category and name strings must have application lifetime (statics or
///   literals). They may not include " chars.
///
#define TRACE_EVENT_INSTANT0(category, name) \
  cef_trace_event_instant(category, name, NULL, 0, NULL, 0)
#define TRACE_EVENT_INSTANT1(category, name, arg1_name, arg1_val) \
  cef_trace_event_instant(category, name, arg1_name, arg1_val, NULL, 0)
#define TRACE_EVENT_INSTANT2(category, name, arg1_name, arg1_val, arg2_name, \
                             arg2_val)                                       \
  cef_trace_event_instant(category, name, arg1_name, arg1_val, arg2_name,    \
                          arg2_val)

///
/// Records a single BEGIN event called "name" immediately, with 0, 1 or 2
/// associated arguments. If the category is not enabled, then this
/// does nothing.
/// - category and name strings must have application lifetime (statics or
///   literals). They may not include " chars.
///
#define TRACE_EVENT_BEGIN0(category, name) \
  cef_trace_event_begin(category, name, NULL, 0, NULL, 0)
#define TRACE_EVENT_BEGIN1(category, name, arg1_name, arg1_val) \
  cef_trace_event_begin(category, name, arg1_name, arg1_val, NULL, 0)
#define TRACE_EVENT_BEGIN2(category, name, arg1_name, arg1_val, arg2_name, \
                           arg2_val)                                       \
  cef_trace_event_begin(category, name, arg1_name, arg1_val, arg2_name,    \
                        arg2_val)

///
/// Records a single END event for "name" immediately. If the category
/// is not enabled, then this does nothing.
/// - category and name strings must have application lifetime (statics or
///   literals). They may not include " chars.
///
#define TRACE_EVENT_END0(category, name) \
  cef_trace_event_end(category, name, NULL, 0, NULL, 0)
#define TRACE_EVENT_END1(category, name, arg1_name, arg1_val) \
  cef_trace_event_end(category, name, arg1_name, arg1_val, NULL, 0)
#define TRACE_EVENT_END2(category, name, arg1_name, arg1_val, arg2_name, \
                         arg2_val)                                       \
  cef_trace_event_end(category, name, arg1_name, arg1_val, arg2_name, arg2_val)

///
/// Records the value of a counter called "name" immediately. Value
/// must be representable as a 32 bit integer.
/// - category and name strings must have application lifetime (statics or
///   literals). They may not include " chars.
///
#define TRACE_COUNTER1(category, name, value) \
  cef_trace_counter(category, name, NULL, value, NULL, 0)

///
/// Records the values of a multi-parted counter called "name" immediately.
/// The UI will treat value1 and value2 as parts of a whole, displaying their
/// values as a stacked-bar chart.
/// - category and name strings must have application lifetime (statics or
///   literals). They may not include " chars.
///
#define TRACE_COUNTER2(category, name, value1_name, value1_val, value2_name, \
                       value2_val)                                           \
  cef_trace_counter(category, name, value1_name, value1_val, value2_name,    \
                    value2_val)

///
/// Records the value of a counter called "name" immediately. Value
/// must be representable as a 32 bit integer.
/// - category and name strings must have application lifetime (statics or
///   literals). They may not include " chars.
/// - |id| is used to disambiguate counters with the same name. It must either
///   be a pointer or an integer value up to 64 bits. If it's a pointer, the
///   bits will be xored with a hash of the process ID so that the same pointer
///   on two different processes will not collide.
///
#define TRACE_COUNTER_ID1(category, name, id, value) \
  cef_trace_counter_id(category, name, id, NULL, value, NULL, 0)

///
/// Records the values of a multi-parted counter called "name" immediately.
/// The UI will treat value1 and value2 as parts of a whole, displaying their
/// values as a stacked-bar chart.
/// - category and name strings must have application lifetime (statics or
///   literals). They may not include " chars.
/// - |id| is used to disambiguate counters with the same name. It must either
///   be a pointer or an integer value up to 64 bits. If it's a pointer, the
///   bits will be xored with a hash of the process ID so that the same pointer
///   on two different processes will not collide.
///
#define TRACE_COUNTER_ID2(category, name, id, value1_name, value1_val, \
                          value2_name, value2_val)                     \
  cef_trace_counter_id(category, name, id, value1_name, value1_val,    \
                       value2_name, value2_val)

///
/// Records a single ASYNC_BEGIN event called "name" immediately, with 0, 1 or 2
/// associated arguments. If the category is not enabled, then this
/// does nothing.
/// - category and name strings must have application lifetime (statics or
///   literals). They may not include " chars.
/// - |id| is used to match the ASYNC_BEGIN event with the ASYNC_END event.
///   ASYNC events are considered to match if their category, name and id values
///   all match. |id| must either be a pointer or an integer value up to 64
///   bits. If it's a pointer, the bits will be xored with a hash of the process
///   ID sothat the same pointer on two different processes will not collide.
/// An asynchronous operation can consist of multiple phases. The first phase is
/// defined by the ASYNC_BEGIN calls. Additional phases can be defined using the
/// ASYNC_STEP_BEGIN macros. When the operation completes, call ASYNC_END.
/// An async operation can span threads and processes, but all events in that
/// operation must use the same |name| and |id|. Each event can have its own
/// args.
///
#define TRACE_EVENT_ASYNC_BEGIN0(category, name, id) \
  cef_trace_event_async_begin(category, name, id, NULL, 0, NULL, 0)
#define TRACE_EVENT_ASYNC_BEGIN1(category, name, id, arg1_name, arg1_val) \
  cef_trace_event_async_begin(category, name, id, arg1_name, arg1_val, NULL, 0)
#define TRACE_EVENT_ASYNC_BEGIN2(category, name, id, arg1_name, arg1_val, \
                                 arg2_name, arg2_val)                     \
  cef_trace_event_async_begin(category, name, id, arg1_name, arg1_val,    \
                              arg2_name, arg2_val)

///
/// Records a single ASYNC_STEP_INTO event for |step| immediately. If the
/// category is not enabled, then this does nothing. The |name| and |id| must
/// match the ASYNC_BEGIN event above. The |step| param identifies this step
/// within the async event. This should be called at the beginning of the next
/// phase of an asynchronous operation. The ASYNC_BEGIN event must not have any
/// ASYNC_STEP_PAST events.
///
#define TRACE_EVENT_ASYNC_STEP_INTO0(category, name, id, step) \
  cef_trace_event_async_step_into(category, name, id, step, NULL, 0)
#define TRACE_EVENT_ASYNC_STEP_INTO1(category, name, id, step, arg1_name, \
                                     arg1_val)                            \
  cef_trace_event_async_step_into(category, name, id, step, arg1_name, arg1_val)

///
/// Records a single ASYNC_STEP_PAST event for |step| immediately. If the
/// category is not enabled, then this does nothing. The |name| and |id| must
/// match the ASYNC_BEGIN event above. The |step| param identifies this step
/// within the async event. This should be called at the beginning of the next
/// phase of an asynchronous operation. The ASYNC_BEGIN event must not have any
/// ASYNC_STEP_INTO events.
///
#define TRACE_EVENT_ASYNC_STEP_PAST0(category, name, id, step) \
  cef_trace_event_async_step_past(category, name, id, step, NULL, 0)
#define TRACE_EVENT_ASYNC_STEP_PAST1(category, name, id, step, arg1_name, \
                                     arg1_val)                            \
  cef_trace_event_async_step_past(category, name, id, step, arg1_name, arg1_val)

///
/// Records a single ASYNC_END event for "name" immediately. If the category
/// is not enabled, then this does nothing.
///
#define TRACE_EVENT_ASYNC_END0(category, name, id) \
  cef_trace_event_async_end(category, name, id, NULL, 0, NULL, 0)
#define TRACE_EVENT_ASYNC_END1(category, name, id, arg1_name, arg1_val) \
  cef_trace_event_async_end(category, name, id, arg1_name, arg1_val, NULL, 0)
#define TRACE_EVENT_ASYNC_END2(category, name, id, arg1_name, arg1_val, \
                               arg2_name, arg2_val)                     \
  cef_trace_event_async_end(category, name, id, arg1_name, arg1_val,    \
                            arg2_name, arg2_val)

namespace cef_trace_event {

///
/// Used by TRACE_EVENTx macro. Do not use directly.
///
class CefTraceEndOnScopeClose {
 public:
  CefTraceEndOnScopeClose(const char* category, const char* name)
      : category_(category), name_(name) {}
  ~CefTraceEndOnScopeClose() {
    cef_trace_event_end(category_, name_, NULL, 0, NULL, 0);
  }

 private:
  const char* category_;
  const char* name_;
};

}  // namespace cef_trace_event

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_TRACE_EVENT_H_
