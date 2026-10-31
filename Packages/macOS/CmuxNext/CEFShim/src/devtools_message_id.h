// The top-level "id" of a DevTools protocol message, without a full JSON
// parse (no CEF needed; scripts/cmux-next/test-shim-devtools-id-cpp.sh).
// A full parse refuses valid protocol output (a lone UTF-16 surrogate
// escape in a string, nesting deeper than the parser allows), which sent
// raw-send replies to the wrong event. This scanner walks only the
// top-level keys and skips every value by string and bracket matching.
#pragma once

#include <cstddef>
#include <cstring>
#include <string>

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

// Whether p[0, n) is the text of one JSON object, spaces around it allowed:
// it starts with '{', its strings close, its brackets nest to depth 0 at its
// end, and nothing follows it. A byte scan with no values built; Chromium
// parses the message once. '{' and '[' count as one kind of bracket, so a
// mismatched closer ({"a":1]) passes the scan: it cannot close the message
// around it early (the depth stays above 0 until the text's own end), and
// Chromium's strict parse refuses the whole message, so the call gets no
// result and times out (CEFRuntime.devToolsTimeout). The host never writes
// such text: its parameters come from JSONSerialization.
inline bool IsOneJSONObject(const char* p, size_t n) {
  using namespace devtools_id_detail;
  size_t i = SkipSpace(p, n, 0);
  if (i >= n || p[i] != '{') return false;
  i = SkipValue(p, n, i);
  return i <= n && SkipSpace(p, n, i) == n;
}

// Whether `method` is a protocol method name: "Domain.method", ASCII
// letters, digits and '_' around one or more dots. It goes into the
// message unquoted by any writer, so nothing else is allowed.
inline bool IsDevToolsMethodName(const char* method) {
  if (!method || !*method) return false;
  bool dot = false;
  char last = '.';
  for (const char* c = method; *c; ++c) {
    const bool word = (*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == '_';
    if (*c == '.') {
      if (last == '.') return false;
      dot = true;
    } else if (!word) {
      return false;
    }
    last = *c;
  }
  return dot && last != '.';
}

// The protocol message of a shim-internal DevTools call, in the format
// CefDevToolsController::ExecuteDevToolsMethod writes
// ({"id":N,"method":"M","params":P}), with the parameters text P put in as
// it is: the caller checked `method` (IsDevToolsMethodName) and P
// (IsOneJSONObject). Empty P: no "params".
inline std::string DevToolsCallMessage(int id, const char* method, const char* params, size_t params_size) {
  std::string message;
  message.reserve(params_size + std::strlen(method) + 48);
  message += "{\"id\":";
  message += std::to_string(id);
  message += ",\"method\":\"";
  message += method;
  message += '"';
  if (params_size > 0) {
    message += ",\"params\":";
    message.append(params, params_size);
  }
  message += '}';
  return message;
}

}  // namespace cmux_shim
