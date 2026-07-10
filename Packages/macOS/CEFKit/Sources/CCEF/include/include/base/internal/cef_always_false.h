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

// This file provides AlwaysFalse<> for use with static_assert() in templates.
// Chromium removed this file in favor of bare static_assert(false) which is
// supported in C++23 and as a defect report back to C++11 in newer compilers.
// CEF retains this for compatibility with older compilers in standalone mode.

#ifndef CEF_INCLUDE_BASE_INTERNAL_CEF_ALWAYS_FALSE_H_
#define CEF_INCLUDE_BASE_INTERNAL_CEF_ALWAYS_FALSE_H_
#pragma once

#if !defined(USING_CHROMIUM_INCLUDES)
// The following is substantially similar to the Chromium implementation
// prior to its removal. This is only needed for CEF standalone builds.

namespace cef_internal {

template <typename... Args>
struct AlwaysFalseHelper {
  static constexpr bool kValue = false;
};

}  // namespace cef_internal

template <typename... Args>
inline constexpr bool AlwaysFalse =
    cef_internal::AlwaysFalseHelper<Args...>::kValue;

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_INTERNAL_CEF_ALWAYS_FALSE_H_
