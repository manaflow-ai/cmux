// cmux-page:// rules that need no CEF (scripts/cmux-next/test-cmux-page-path-cpp.sh
// compiles this header alone): page ids, the fixed MIME table, and the path
// check that keeps every response below the page's resource root.
#ifndef CMUX_SHIM_CMUX_PAGE_PATH_H_
#define CMUX_SHIM_CMUX_PAGE_PATH_H_

#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>

#include <string>

namespace cmux_shim {

inline constexpr char kCmuxPageScheme[] = "cmux-page";
inline constexpr char kCmuxPageDefaultCSP[] = "default-src 'self'";

// Lowercases `id` into *out when it is a valid page id (the URL host):
// 1-253 characters of [a-z0-9.-], no empty label, no label that starts or
// ends with '-'. Leaves *out empty and returns false otherwise.
inline bool NormalizePageId(const std::string& id, std::string* out) {
  out->clear();
  if (id.empty() || id.size() > 253) return false;
  std::string lower;
  lower.reserve(id.size());
  for (char c : id) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-')) return false;
    lower.push_back(c);
  }
  size_t start = 0;
  while (true) {
    size_t dot = lower.find('.', start);
    size_t end = dot == std::string::npos ? lower.size() : dot;
    if (end == start || lower[start] == '-' || lower[end - 1] == '-') return false;
    if (dot == std::string::npos) break;
    start = dot + 1;
  }
  *out = lower;
  return true;
}

// Whether a normalized (lowercase) page id is reserved for first-party
// pages: "cmux" and every "cmux." id, the same namespace as PageID.isReserved
// in CmuxNextPages. Only cmux_shim_page_scheme_add_first_party serves them.
inline bool IsReservedPageId(const std::string& lower_id) {
  return lower_id == "cmux" || lower_id.rfind("cmux.", 0) == 0;
}

// The MIME type for the file name's extension, or nullptr: only this
// table is served (lowercase extensions only).
inline const char* PageMimeType(const std::string& path) {
  size_t slash = path.rfind('/');
  size_t dot = path.rfind('.');
  if (dot == std::string::npos || (slash != std::string::npos && dot < slash)) return nullptr;
  const std::string ext = path.substr(dot + 1);
  static const struct {
    const char* ext;
    const char* mime;
  } kTable[] = {
      {"html", "text/html"},       {"js", "text/javascript"}, {"mjs", "text/javascript"},
      {"css", "text/css"},         {"json", "application/json"}, {"svg", "image/svg+xml"},
      {"wasm", "application/wasm"}, {"woff", "font/woff"},    {"woff2", "font/woff2"},
      {"ttf", "font/ttf"},         {"otf", "font/otf"},
  };
  for (const auto& entry : kTable) {
    if (ext == entry.ext) return entry.mime;
  }
  return nullptr;
}

namespace page_detail {

inline int HexValue(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Percent-decodes once. False on a bad or truncated escape or a NUL.
inline bool PercentDecode(const std::string& in, std::string* out) {
  out->clear();
  for (size_t i = 0; i < in.size(); ++i) {
    char c = in[i];
    if (c == '%') {
      if (i + 2 >= in.size()) return false;
      int hi = HexValue(in[i + 1]);
      int lo = HexValue(in[i + 2]);
      if (hi < 0 || lo < 0) return false;
      c = static_cast<char>(hi * 16 + lo);
      i += 2;
    }
    if (c == '\0') return false;
    out->push_back(c);
  }
  return true;
}

inline bool RealPath(const std::string& path, std::string* out) {
  char buffer[PATH_MAX];
  if (!realpath(path.c_str(), buffer)) return false;
  *out = buffer;
  return true;
}

}  // namespace page_detail

// Resolves the URL path of a cmux-page:// request below `root`. On success
// writes the real path of a regular file below the real root and its MIME
// type and returns true. Everything else is a 404 (returns false, leaves
// both outputs empty): a path that is not absolute, a bad escape, a NUL, a
// backslash, a "." or ".." component (also percent-encoded), a missing
// file or a directory, a real path outside the root (symlink escapes;
// compared component-wise, so /root2 is not below /root), or a type
// outside the MIME table. "/" and paths ending in "/" serve index.html.
inline bool ResolvePagePath(const std::string& root, const std::string& url_path, std::string* file,
                            std::string* mime) {
  file->clear();
  mime->clear();
  if (url_path.empty() || url_path[0] != '/') return false;
  std::string decoded;
  if (!page_detail::PercentDecode(url_path, &decoded)) return false;
  if (decoded.find('\\') != std::string::npos) return false;
  std::string relative;
  size_t start = 1;
  while (start <= decoded.size()) {
    size_t slash = decoded.find('/', start);
    std::string part = decoded.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
    if (part == "." || part == "..") return false;
    if (!part.empty()) {
      if (!relative.empty()) relative.push_back('/');
      relative += part;
    }
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  if (decoded.back() == '/') relative += relative.empty() ? "index.html" : "/index.html";
  std::string real_root;
  if (!page_detail::RealPath(root, &real_root)) return false;
  struct stat root_info;
  if (stat(real_root.c_str(), &root_info) != 0 || !S_ISDIR(root_info.st_mode)) return false;
  std::string real_file;
  if (!page_detail::RealPath(real_root + "/" + relative, &real_file)) return false;
  // Component-wise: the real file must be strictly below the real root.
  const std::string prefix = real_root == "/" ? "/" : real_root + "/";
  if (real_file.size() <= prefix.size() || real_file.compare(0, prefix.size(), prefix) != 0) return false;
  struct stat info;
  if (stat(real_file.c_str(), &info) != 0 || !S_ISREG(info.st_mode)) return false;
  const char* type = PageMimeType(real_file);
  if (!type) return false;
  *file = real_file;
  *mime = type;
  return true;
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_CMUX_PAGE_PATH_H_
