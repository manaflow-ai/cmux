// The shim's unsafe-buffer escape hatch, Chromium's (base/compiler_specific.h,
// docs/unsafe_buffers.md). The shim builds with -Werror=unsafe-buffer-usage
// (scripts/cmux-next/build-cef-shim.sh): pointer arithmetic, pointer
// subscripts, two-argument std::span and the unchecked libc buffer calls do
// not compile. Code uses std::span, std::string_view and containers instead;
// the C ABI's (pointer, count) arrays become spans once, at the boundary.
//
// UNSAFE_BUFFERS(expr) compiles one such operation. Every use has a
// `// SAFETY:` comment right above it that says why the bounds hold.
// UNSAFE_BUFFER_USAGE marks a function whose callers must prove the bounds:
// each call is itself inside UNSAFE_BUFFERS with a SAFETY comment.
// No CEF needed: the header-only tests include this file.
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdlib>
#include <span>
#include <string_view>

#if defined(__clang__)
#define UNSAFE_BUFFERS(...)                  \
  _Pragma("clang unsafe_buffer_usage begin") \
  __VA_ARGS__                                \
  _Pragma("clang unsafe_buffer_usage end")
#else
#define UNSAFE_BUFFERS(...) __VA_ARGS__
#endif

#if defined(__has_cpp_attribute)
#if __has_cpp_attribute(clang::unsafe_buffer_usage)
#define UNSAFE_BUFFER_USAGE [[clang::unsafe_buffer_usage]]
#endif
#endif
#ifndef UNSAFE_BUFFER_USAGE
#define UNSAFE_BUFFER_USAGE
#endif

namespace cmux_shim {

// A C ABI array, `count` elements at `data`, as a span (Chromium's
// UNSAFE_BUFFERS(base::span(ptr, size)) at an API edge). Empty for a NULL
// `data` or a `count` <= 0, so a caller never builds a span over NULL.
template <typename T, typename Count>
UNSAFE_BUFFER_USAGE std::span<T> SpanFromCArray(T* data, Count count) {
  if (!data || count <= 0) return {};
  // SAFETY: the caller proves `data` points at `count` live elements; the
  // count is positive here, so the size_t conversion keeps its value.
  return UNSAFE_BUFFERS(std::span<T>(data, static_cast<size_t>(count)));
}

// Writes `text` into `out` as a NUL-terminated string, cut to fit as
// snprintf cuts it; nothing for an empty `out`.
inline void WriteCString(std::span<char> out, std::string_view text) {
  if (out.empty()) return;
  const std::string_view kept = text.substr(0, out.size() - 1);
  std::ranges::copy(kept, out.begin());
  out[kept.size()] = '\0';
}

// A malloc'd NUL-terminated copy of `text` for the app (what strdup
// returns); NULL when out of memory.
inline char* OwnedCString(std::string_view text) {
  char* raw = static_cast<char*>(std::malloc(text.size() + 1));
  if (!raw) return nullptr;
  // SAFETY: `raw` is a new allocation of text.size() + 1 bytes.
  WriteCString(UNSAFE_BUFFERS(std::span<char>(raw, text.size() + 1)), text);
  return raw;
}

}  // namespace cmux_shim
