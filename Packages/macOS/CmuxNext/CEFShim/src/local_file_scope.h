// The local file scope of a CEF tab (cx-ary1f): a file: page loads file:
// subresources and subframes only from its own folder or below, the folder a
// WebKit tab grants with loadFileURL(_:allowingReadAccessTo:)
// (WebKitTab+Navigations.swift). Chromium's own default lets a file: page
// show any local image. The shim cancels the rest in its resource request
// handler (shim_client.mm); main-frame navigations are not subresources and
// keep their own rules. The check reads the URL's path and does not resolve
// symlinks: a link inside the folder that points out of it is followed. Such a
// link is already on the user's disk, and a file: page cannot read back what
// it shows, though an image's load or error event and its natural size do
// tell the page whether the link's target exists and roughly how large it is. No CEF dependency, so the test compiles it alone
// (scripts/cmux-next/test-local-file-scope-cpp.sh,
// schemas/local-file-scope/vectors.json).
#pragma once

#include <cctype>
#include <string>
#include <string_view>
#include <vector>

namespace cmux_shim {

struct LocalFilePath {
  bool valid = false;
  std::string host;                   // lowercased; "" for a local file
  std::vector<std::string> segments;  // decoded, with "." and ".." resolved
  bool directory = false;             // the path ends in "/"
};

inline bool LocalFileSchemeURL(const std::string& url) {
  constexpr std::string_view kScheme = "file:";
  if (url.size() < kScheme.size()) return false;
  for (size_t i = 0; i < kScheme.size(); ++i) {
    if (std::tolower(static_cast<unsigned char>(url[i])) != kScheme[i]) return false;
  }
  return true;
}

inline int LocalFileHexDigit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// A file: URL's host and path. The path is percent-decoded before "." and
// ".." resolve, so an encoded dot or slash cannot step out of a folder; a
// decoded backslash or NUL makes the path invalid (refused).
inline LocalFilePath ParseLocalFilePath(const std::string& url) {
  LocalFilePath out;
  if (!LocalFileSchemeURL(url)) return out;
  std::string rest = url.substr(5);
  rest = rest.substr(0, rest.find_first_of("?#"));
  if (rest.compare(0, 2, "//") == 0) {
    size_t slash = rest.find('/', 2);
    std::string host = rest.substr(2, slash == std::string::npos ? std::string::npos : slash - 2);
    for (char& c : host) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    out.host = host == "localhost" ? "" : host;
    rest = slash == std::string::npos ? "" : rest.substr(slash);
  }
  if (rest.empty() || rest[0] != '/') return out;
  std::string path;
  for (size_t i = 0; i < rest.size(); ++i) {
    int high = rest[i] == '%' && i + 2 < rest.size() ? LocalFileHexDigit(rest[i + 1]) : -1;
    int low = high >= 0 ? LocalFileHexDigit(rest[i + 2]) : -1;
    if (high >= 0 && low >= 0) {
      path.push_back(static_cast<char>(high * 16 + low));
      i += 2;
    } else {
      path.push_back(rest[i]);
    }
  }
  if (path.find('\\') != std::string::npos || path.find('\0') != std::string::npos) return out;
  size_t start = 0;
  while (start <= path.size()) {
    size_t end = path.find('/', start);
    std::string segment = path.substr(start, end == std::string::npos ? std::string::npos : end - start);
    if (segment == "..") {
      if (!out.segments.empty()) out.segments.pop_back();
    } else if (!segment.empty() && segment != ".") {
      out.segments.push_back(segment);
    }
    if (end == std::string::npos) break;
    start = end + 1;
  }
  out.directory = path.back() == '/';
  out.valid = true;
  return out;
}

// Whether `url` is a known web document whose file: requests Chromium refuses
// itself (none of these schemes is registered as local). Matched from the
// first character, case-insensitively: any other document, including one the
// shim cannot place (empty, about:, data:, filesystem:, blob:), an unknown
// scheme or a URL that does not start with its scheme, loads no file.
inline bool LocalFileWebDocument(const std::string& url) {
  static constexpr std::string_view kSchemes[] = {"http:",     "https:",           "chrome-extension:", "chrome:",
                                                  "devtools:", "chrome-untrusted:", "cmux-page:"};
  for (const std::string_view scheme : kSchemes) {
    size_t i = 0;
    while (i < scheme.size() && i < url.size() &&
           std::tolower(static_cast<unsigned char>(url[i])) == scheme[i]) {
      ++i;
    }
    if (i == scheme.size()) return true;
  }
  return false;
}

// Whether a file: subresource or subframe request from `document_url` loads.
// A request that is not file: is left to Chromium (true), and so is one from
// a known web document (LocalFileWebDocument), which Chromium refuses itself.
// Any other document that is not file: loads no file. A file: document loads
// only files under its own folder on the same host.
inline bool LocalFileSubresourceAllowed(const std::string& document_url, const std::string& request_url) {
  if (!LocalFileSchemeURL(request_url)) return true;
  if (!LocalFileSchemeURL(document_url)) return LocalFileWebDocument(document_url);
  LocalFilePath document = ParseLocalFilePath(document_url);
  LocalFilePath request = ParseLocalFilePath(request_url);
  if (!document.valid || !request.valid || document.host != request.host) return false;
  size_t folder = document.segments.size();
  if (!document.directory && folder > 0) --folder;
  if (request.segments.size() <= folder) return false;
  for (size_t i = 0; i < folder; ++i) {
    if (request.segments[i] != document.segments[i]) return false;
  }
  return true;
}

}  // namespace cmux_shim
