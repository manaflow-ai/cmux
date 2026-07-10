// Copyright (c) 2023 Marshall A. Greenblatt. Portions copyright (c) 2023
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

#ifndef CEF_INCLUDE_BASE_CEF_IS_INSTANTIATION_H_
#define CEF_INCLUDE_BASE_CEF_IS_INSTANTIATION_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/types/is_instantiation.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include <type_traits>

namespace base {
namespace cef_internal {

// True if and only if `T` is `C<Types...>` for some set of types, i.e. `T` is
// an instantiation of the template `C`.
//
// This is false by default. We specialize it to true below for pairs of
// arguments that satisfy the condition.
template <typename T, template <typename...> class C>
inline constexpr bool is_instantiation_v = false;

template <template <typename...> class C, typename... Ts>
inline constexpr bool is_instantiation_v<C<Ts...>, C> = true;

}  // namespace cef_internal

/// True if and only if the type `T` is an instantiation of the template `C`
/// with some set of type arguments.
///
/// Note that there is no allowance for reference or const/volatile qualifiers;
/// if these are a concern you probably want to feed through `std::decay_t<T>`.
template <typename T, template <typename...> class C>
concept is_instantiation = cef_internal::is_instantiation_v<T, C>;

}  // namespace base

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_IS_INSTANTIATION_H_
