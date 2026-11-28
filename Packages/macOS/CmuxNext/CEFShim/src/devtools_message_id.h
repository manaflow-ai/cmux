// The top-level "id" of a DevTools protocol message, without a full JSON
// parse (no CEF needed; scripts/cmux-next/test-shim-devtools-id-cpp.sh).
// A full parse refuses valid protocol output (a lone UTF-16 surrogate
// escape in a string, nesting deeper than the parser allows), which sent
// raw-send replies to the wrong event. This scanner walks only the
// top-level keys and skips every value by string and bracket matching.
#pragma once

#include <cstddef>
#include <cstring>

namespace cmux_shim {

enum class DevToolsIdKind {
  kNone,     // a JSON object without a top-level "id" (an event)
  kInt,      // one integer "id"
  kInvalid,  // not an object, malformed, a non-integer or repeated "id"
};

namespace devtools_id_detail {

inline bool Space(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

inline size_t SkipSpace(const char* p, size_t n, size_t i) {
  while (i < n && Space(p[i])) ++i;
  return i;
}

// p[i] is '"'. Index after the closing quote, or n + 1.
inline size_t SkipString(const char* p, size_t n, size_t i) {
  for (++i; i < n; ++i) {
    if (p[i] == '\\') {
      ++i;
    } else if (p[i] == '"') {
      return i + 1;
    }
  }
  return n + 1;
}

// One value starting at p[i]. Index after it, or n + 1.
inline size_t SkipValue(const char* p, size_t n, size_t i) {
  if (i >= n) return n + 1;
  if (p[i] == '"') return SkipString(p, n, i);
  if (p[i] == '{' || p[i] == '[') {
    size_t depth = 0;
    while (i < n) {
      const char c = p[i];
      if (c == '"') {
        i = SkipString(p, n, i);
        if (i > n) return n + 1;
        continue;
      }
      if (c == '{' || c == '[') {
        ++depth;
      } else if (c == '}' || c == ']') {
        if (--depth == 0) return i + 1;
      }
      ++i;
    }
    return n + 1;
  }
  const size_t start = i;
  while (i < n && p[i] != ',' && p[i] != '}' && p[i] != ']' && !Space(p[i])) ++i;
  return i == start ? n + 1 : i;
}

}  // namespace devtools_id_detail

inline DevToolsIdKind TopLevelDevToolsId(const char* p, size_t n, long long* id) {
  using namespace devtools_id_detail;
  size_t i = SkipSpace(p, n, 0);
  if (i >= n || p[i] != '{') return DevToolsIdKind::kInvalid;
  i = SkipSpace(p, n, i + 1);
  bool found = false;
  long long value = 0;
  if (i < n && p[i] == '}') return DevToolsIdKind::kNone;
  while (true) {
    if (i >= n || p[i] != '"') return DevToolsIdKind::kInvalid;
    const size_t key_start = i + 1;
    const size_t key_end = SkipString(p, n, i);
    if (key_end > n) return DevToolsIdKind::kInvalid;
    const bool is_id = key_end - 1 - key_start == 2 && std::memcmp(p + key_start, "id", 2) == 0;
    i = SkipSpace(p, n, key_end);
    if (i >= n || p[i] != ':') return DevToolsIdKind::kInvalid;
    i = SkipSpace(p, n, i + 1);
    if (is_id) {
      if (found) return DevToolsIdKind::kInvalid;
      bool negative = false;
      if (i < n && p[i] == '-') {
        negative = true;
        ++i;
      }
      size_t digits = 0;
      long long v = 0;
      while (i < n && p[i] >= '0' && p[i] <= '9') {
        if (++digits > 18) return DevToolsIdKind::kInvalid;
        v = v * 10 + (p[i] - '0');
        ++i;
      }
      if (digits == 0 || (i < n && p[i] != ',' && p[i] != '}' && !Space(p[i]))) {
        return DevToolsIdKind::kInvalid;
      }
      found = true;
      value = negative ? -v : v;
    } else {
      i = SkipValue(p, n, i);
      if (i > n) return DevToolsIdKind::kInvalid;
    }
    i = SkipSpace(p, n, i);
    if (i >= n) return DevToolsIdKind::kInvalid;
    if (p[i] == '}') break;
    if (p[i] != ',') return DevToolsIdKind::kInvalid;
    i = SkipSpace(p, n, i + 1);
  }
  if (SkipSpace(p, n, i + 1) != n) return DevToolsIdKind::kInvalid;
  if (!found) return DevToolsIdKind::kNone;
  *id = value;
  return DevToolsIdKind::kInt;
}

}  // namespace cmux_shim
