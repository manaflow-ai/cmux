// Packed cmux-page:// files (CMUX-570, app size), with no CEF (scripts/cmux-next/test-cmux-page-path-cpp.sh
// compiles this header alone, with zlib). The app build stores the viewers' lazy chunks
// (markdown-viewer/webviews-app/chunks) as `<name>.deflate`, raw DEFLATE
// (scripts/cmux-next/pack-webviews-chunks.py), and the pages' `__shared` scripts the same way
// (webviews/scripts/pages/pack-pages.mjs). A request for a file the folder does not hold is served
// from its packed copy beside it, inflated in memory (shim_page_scheme.mm), as the app's own handler
// does for WebKit and the live web loop (CmuxNextPages PagePackedFile.swift). The file itself, when it
// is there, always wins.
#ifndef CMUX_SHIM_CMUX_PAGE_PACKED_H_
#define CMUX_SHIM_CMUX_PAGE_PACKED_H_

#include <stdio.h>
#include <zlib.h>

#include <algorithm>
#include <string>

#include "cmux_page_path.h"

namespace cmux_shim {

// The suffix of a packed file (pack-webviews-chunks.py SUFFIX, pack-pages.mjs PACKED_SUFFIX,
// PagePackedFile.suffix).
inline constexpr char kPackedPageSuffix[] = ".deflate";
// The largest file a packed copy may inflate to (the largest chunk is about 3.6 MB): a broken or
// hostile copy ends as a 404, never as an allocation without bound.
inline constexpr size_t kPackedPageMaxBytes = 64u << 20;
// The largest packed copy read.
inline constexpr size_t kPackedPageMaxStoredBytes = 32u << 20;

// For a request ResolvePagePath answers 404: the packed copy of the file `url_path` names, by the same
// rules (below the real root, no escape, a regular file). Its real name must be the file's name plus
// the suffix (a link may not make it stand for a file of another name), and that name must have a
// type in the MIME table: writes the packed copy's real path and the file's MIME type and returns
// true. False otherwise, with both outputs empty.
inline bool ResolvePackedPagePath(const std::string& root, const std::string& url_path, std::string* packed,
                                  std::string* mime) {
  packed->clear();
  mime->clear();
  std::string real;
  if (!page_detail::ResolvePageFile(root, url_path, kPackedPageSuffix, &real)) return false;
  std::string decoded;
  if (!page_detail::PercentDecode(url_path, &decoded)) return false;
  std::string name = decoded.substr(decoded.rfind('/') + 1);
  if (name.empty()) name = "index.html";
  const std::string want = "/" + name + kPackedPageSuffix;
  if (real.size() <= want.size() || real.compare(real.size() - want.size(), want.size(), want) != 0) return false;
  const char* type = PageMimeType(name);
  if (!type) return false;
  *packed = real;
  *mime = type;
  return true;
}

// Inflates raw DEFLATE (RFC 1951, no zlib header: node's deflateRawSync, Python's wbits -15) into
// *out. False for a stream that is broken, does not end, has bytes after its end, or inflates past
// `max` bytes (*out is then empty).
inline bool InflateRawPage(const std::string& stored, std::string* out, size_t max = kPackedPageMaxBytes) {
  out->clear();
  z_stream stream{};
  if (inflateInit2(&stream, -15) != Z_OK) return false;
  stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(stored.data()));
  stream.avail_in = static_cast<uInt>(stored.size());
  // Text inflates about three to four times; start there and double.
  std::string buffer(std::min(max, std::max<size_t>(stored.size() * 4, 4096)), '\0');
  size_t produced = 0;
  int status = Z_OK;
  while (true) {
    if (produced == buffer.size()) {
      if (buffer.size() >= max) break;
      buffer.resize(std::min(max, buffer.size() * 2));
    }
    stream.next_out = reinterpret_cast<Bytef*>(&buffer[produced]);
    stream.avail_out = static_cast<uInt>(buffer.size() - produced);
    status = inflate(&stream, Z_NO_FLUSH);
    produced = buffer.size() - stream.avail_out;
    if (status != Z_OK) break;
    if (stream.avail_in == 0 && stream.avail_out != 0) break;  // input ran out before the end
  }
  const bool ok = status == Z_STREAM_END && stream.avail_in == 0;
  inflateEnd(&stream);
  if (!ok) return false;
  buffer.resize(produced);
  *out = std::move(buffer);
  return true;
}

// Reads the packed copy `path` (ResolvePackedPagePath) and inflates it into *out.
inline bool ReadPackedPage(const std::string& path, std::string* out) {
  out->clear();
  FILE* file = fopen(path.c_str(), "rb");
  if (!file) return false;
  std::string stored;
  char chunk[64 * 1024];
  size_t read = 0;
  bool ok = true;
  while ((read = fread(chunk, 1, sizeof(chunk), file)) > 0) {
    if (stored.size() + read > kPackedPageMaxStoredBytes) {
      ok = false;
      break;
    }
    stored.append(chunk, read);
  }
  if (ferror(file)) ok = false;
  fclose(file);
  return ok && InflateRawPage(stored, out);
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_CMUX_PAGE_PACKED_H_
