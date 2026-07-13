// Copyright 2019 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// The following macros are used to declare both the color id enumerations and
// the stringized names of the enumeration elements for use in dump_colors. To
// stringize the element names, define STRINGIZE_COLOR_IDS prior to including
// this file. This file is intended to be included just before and just after
// the enumeration or string array declarations.

#if !defined(COLOR_ID_MACROS_DEFINED)
#define COLOR_ID_MACROS_DEFINED
#if defined(STRINGIZE_COLOR_IDS)
// Convert first token to string, throw away the rest.
#define D1(enum_name) #enum_name
#define D2(enum_name, enum_value) #enum_name
#else  // defined(STRINGIZE_COLOR_IDS)
// Declare enum with optional assigned value.
#define D1(enum_name) enum_name
#define D2(enum_name, enum_value) enum_name = enum_value
#endif  // defined(STRINGIZE_COLOR_IDS)
// Select which token in the declaration is the assigned value.
// Use first and optional third token, ignore optional second.
#define E1(enum_name) D1(enum_name)
#define E2(enum_name, old_enum_name) D1(enum_name)
#define E3(enum_name, old_enum_name, enum_value) D2(enum_name, enum_value)
#define GET_E(_1, _2, _3, macro_name, ...) macro_name
#if defined(COMPILER_MSVC)
// Workaround for MSVC not properly expanding __VA_ARGS__.
#define EXPAND(x) x
#define E_CPONLY(...) EXPAND(E(__VA_ARGS__))
#define E(...) EXPAND(GET_E(__VA_ARGS__, E3, E2, E1)(__VA_ARGS__)),
#else  // !defined(COMPILER_MSVC)
#define E_CPONLY(...) E(__VA_ARGS__)
#define E(...) GET_E(__VA_ARGS__, E3, E2, E1)(__VA_ARGS__),
#endif // !defined(COMPILER_MSVC)
#else  // !defined(COLOR_ID_MACROS_DEFINED)
#undef D1
#undef D2
#undef E1
#undef E2
#undef E3
#if defined(COMPILER_MSVC)
#undef EXPAND
#endif
#undef E_CPONLY
#undef GET_E
#undef E
#undef COLOR_ID_MACROS_DEFINED
#endif  // !defined(COLOR_ID_MACROS_DEFINED)
