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

#ifndef CEF_INCLUDE_INTERNAL_CEF_TRACE_EVENT_INTERNAL_H_
#define CEF_INCLUDE_INTERNAL_CEF_TRACE_EVENT_INTERNAL_H_
#pragma once

#include "include/internal/cef_export.h"
#include "include/internal/cef_types.h"

#ifdef __cplusplus
extern "C" {
#endif

// See include/base/cef_trace_event.h for macros and intended usage.

// Functions for tracing counters and functions; called from macros.
// - |category| string must have application lifetime (static or literal). They
//   may not include "(quotes) chars.
// - |argX_name|, |argX_val|, |valueX_name|, |valeX_val| are optional parameters
//   and represent pairs of name and values of arguments
// - |id| is used to disambiguate counters with the same name, or match async
//   trace events

CEF_EXPORT void cef_trace_event_instant(const char* category,
                                        const char* name,
                                        const char* arg1_name,
                                        uint64_t arg1_val,
                                        const char* arg2_name,
                                        uint64_t arg2_val);
CEF_EXPORT void cef_trace_event_begin(const char* category,
                                      const char* name,
                                      const char* arg1_name,
                                      uint64_t arg1_val,
                                      const char* arg2_name,
                                      uint64_t arg2_val);
CEF_EXPORT void cef_trace_event_end(const char* category,
                                    const char* name,
                                    const char* arg1_name,
                                    uint64_t arg1_val,
                                    const char* arg2_name,
                                    uint64_t arg2_val);
CEF_EXPORT void cef_trace_counter(const char* category,
                                  const char* name,
                                  const char* value1_name,
                                  uint64_t value1_val,
                                  const char* value2_name,
                                  uint64_t value2_val);
CEF_EXPORT void cef_trace_counter_id(const char* category,
                                     const char* name,
                                     uint64_t id,
                                     const char* value1_name,
                                     uint64_t value1_val,
                                     const char* value2_name,
                                     uint64_t value2_val);
CEF_EXPORT void cef_trace_event_async_begin(const char* category,
                                            const char* name,
                                            uint64_t id,
                                            const char* arg1_name,
                                            uint64_t arg1_val,
                                            const char* arg2_name,
                                            uint64_t arg2_val);
CEF_EXPORT void cef_trace_event_async_step_into(const char* category,
                                                const char* name,
                                                uint64_t id,
                                                uint64_t step,
                                                const char* arg1_name,
                                                uint64_t arg1_val);
CEF_EXPORT void cef_trace_event_async_step_past(const char* category,
                                                const char* name,
                                                uint64_t id,
                                                uint64_t step,
                                                const char* arg1_name,
                                                uint64_t arg1_val);
CEF_EXPORT void cef_trace_event_async_end(const char* category,
                                          const char* name,
                                          uint64_t id,
                                          const char* arg1_name,
                                          uint64_t arg1_val,
                                          const char* arg2_name,
                                          uint64_t arg2_val);

#ifdef __cplusplus
}
#endif  // __cplusplus

#endif  // CEF_INCLUDE_INTERNAL_CEF_TRACE_EVENT_INTERNAL_H_
