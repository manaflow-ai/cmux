// Copyright (c) 2024 Marshall A. Greenblatt. Portions copyright (c) 2024
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

#ifndef CEF_INCLUDE_BASE_CEF_TO_ADDRESS_H_
#define CEF_INCLUDE_BASE_CEF_TO_ADDRESS_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/types/to_address.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include <memory>
#include <type_traits>

// SFINAE-compatible wrapper for `std::to_address()`.
//
// The standard does not require `std::to_address()` to be SFINAE-compatible
// when code attempts instantiation with non-pointer-like types, and libstdc++'s
// implementation hard errors. For the sake of templated code that wants simple,
// unified handling, CEF instead uses this wrapper, which provides that
// guarantee. This allows code to use "`to_address()` would be valid here" as a
// constraint to detect pointer-like types.
namespace base {

/// Note that calling `std::to_address()` with a function pointer renders the
/// program ill-formed.
template <typename T>
  requires(!std::is_function_v<T>)
constexpr T* to_address(T* p) noexcept {
  return p;
}

/// These constraints cover the cases where `std::to_address()`'s fancy pointer
/// overload is well-specified.
///
/// Note: We check for P::element_type or operator->() instead of directly
/// checking std::pointer_traits<P>::to_address(p) because on GCC 10's
/// libstdc++, instantiating std::pointer_traits<P> for non-pointer-like
/// types triggers a static_assert that cannot be caught by SFINAE/requires.
template <typename P>
  requires requires { typename P::element_type; } ||
           requires(const P& p) { p.operator->(); }
constexpr auto to_address(const P& p) noexcept {
  if constexpr (requires { typename P::element_type; }) {
    // Type has element_type, so std::pointer_traits<P> is well-formed.
    return std::to_address(p);
  } else {
    // Type only has operator->(), recurse on its return type.
    return base::to_address(p.operator->());
  }
}

}  // namespace base

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_TO_ADDRESS_H_
