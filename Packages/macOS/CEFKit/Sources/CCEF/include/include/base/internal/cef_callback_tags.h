// Copyright (c) 2025 Marshall A. Greenblatt. Portions copyright (c) 2022
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

// This defines helpful tags for dealing with Callbacks. Those tags can be used
// to construct special callbacks. This lives in its own file to avoid circular
// dependencies.

#ifndef CEF_INCLUDE_BASE_INTERNAL_CEF_CALLBACK_TAGS_H_
#define CEF_INCLUDE_BASE_INTERNAL_CEF_CALLBACK_TAGS_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/functional/callback_tags.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include <tuple>
#include <utility>

namespace base::cef_internal {

struct NullCallbackTag {
  template <typename Signature>
  struct WithSignature {};
};

struct DoNothingCallbackTag {
  template <typename Signature>
  struct WithSignature {};

  template <typename... BoundArgs>
  struct WithBoundArguments {
    std::tuple<BoundArgs...> bound_args;

    constexpr explicit WithBoundArguments(BoundArgs... args)
        : bound_args(std::forward<BoundArgs>(args)...) {}
  };
};

}  // namespace base::cef_internal

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_INTERNAL_CEF_CALLBACK_TAGS_H_
