// The local file handoff of a CEF tab: a main-frame navigation to a local
// Markdown file, or to video or audio this build cannot decode, is cancelled
// and reported as LOCAL_FILE_HANDOFF, and cmux opens the file where it shows
// (the markdown page, or a WebKit tab, which plays H.264/HEVC and AAC through
// AVFoundation). The fork builds without proprietary codecs
// (plans/cmux-next/browser.md). The Swift copy is LocalFileHandoff
// (CmuxNextBrowser/Core/LocalFileHandoff.swift); both pass
// schemas/local-file-handoff/vectors.json
// (scripts/cmux-next/test-local-file-handoff-cpp.sh). No CEF dependency, so the
// test compiles it alone.
#pragma once

#include <cctype>
#include <string>

namespace cmux_shim {

inline std::string LowerASCII(std::string text) {
  for (char& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return text;
}

inline int HexDigit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

inline std::string PercentDecoded(const std::string& text) {
  std::string out;
  for (size_t i = 0; i < text.size(); ++i) {
    int high = text[i] == '%' && i + 2 < text.size() ? HexDigit(text[i + 1]) : -1;
    int low = high >= 0 ? HexDigit(text[i + 2]) : -1;
    if (high >= 0 && low >= 0) {
      out.push_back(static_cast<char>(high * 16 + low));
      i += 2;
    } else {
      out.push_back(text[i]);
    }
  }
  return out;
}

// The lowercased extension of a file: URL's last path component, "" for any
// other URL or a name without one. Like Foundation's pathExtension: the query
// and fragment are not part of the path, and the name is percent-decoded.
inline std::string LocalFileExtension(const std::string& url) {
  if (url.size() < 5 || LowerASCII(url.substr(0, 5)) != "file:") return "";
  size_t end = url.find_first_of("?#", 5);
  std::string path = url.substr(5, end == std::string::npos ? std::string::npos : end - 5);
  size_t slash = path.find_last_of('/');
  std::string name = PercentDecoded(slash == std::string::npos ? path : path.substr(slash + 1));
  size_t dot = name.find_last_of('.');
  if (dot == std::string::npos || dot == 0 || dot + 1 == name.size()) return "";
  return LowerASCII(name.substr(dot + 1));
}

// Whether a CEF tab hands the main-frame navigation to `url` off: Markdown
// (md, markdown) and H.264/HEVC or AAC media (mp4, mov, m4v, m4a, aac).
inline bool CEFHandsOffLocalFile(const std::string& url) {
  static const char* const kExtensions[] = {"md", "markdown", "mp4", "mov", "m4v", "m4a", "aac"};
  std::string extension = LocalFileExtension(url);
  if (extension.empty()) return false;
  for (const char* candidate : kExtensions) {
    if (extension == candidate) return true;
  }
  return false;
}

}  // namespace cmux_shim
