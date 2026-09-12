// Copyright (c) 2022 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_CEF_SHARED_PROCESS_MESSAGE_BUILDER_H_
#define CEF_INCLUDE_CEF_SHARED_PROCESS_MESSAGE_BUILDER_H_
#pragma once

#include "include/cef_process_message.h"

///
/// Class that builds a CefProcessMessage containing a shared memory region.
/// This class is not thread-safe but may be used exclusively on a different
/// thread from the one which constructed it.
///
/*--cef(source=library)--*/
class CefSharedProcessMessageBuilder : public virtual CefBaseRefCounted {
 public:
  ///
  /// Creates a new CefSharedProcessMessageBuilder with the specified |name| and
  /// shared memory region of specified |byte_size|.
  ///
  /*--cef()--*/
  static CefRefPtr<CefSharedProcessMessageBuilder> Create(const CefString& name,
                                                          size_t byte_size);
  ///
  /// Returns true if the builder is valid.
  ///
  /*--cef()--*/
  virtual bool IsValid() = 0;

  ///
  /// Returns the size of the shared memory region in bytes. Returns 0 for
  /// invalid instances.
  ///
  /*--cef()--*/
  virtual size_t Size() = 0;

  ///
  /// Returns the pointer to the writable memory. Returns nullptr for invalid
  /// instances. The returned pointer is only valid for the life span of this
  /// object.
  ///
  /*--cef()--*/
  virtual void* Memory() = 0;

  ///
  /// Creates a new CefProcessMessage from the data provided to the builder.
  /// Returns nullptr for invalid instances. Invalidates the builder instance.
  ///
  /*--cef()--*/
  virtual CefRefPtr<CefProcessMessage> Build() = 0;
};

#endif  // CEF_INCLUDE_CEF_SHARED_PROCESS_MESSAGE_BUILDER_H_
