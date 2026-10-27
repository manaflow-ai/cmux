// Dragging out of a hosted page (plans/cmux-next/chrome-parity/p01-process.md,
// task p01-process-051). With the fork's cmux_set_drag_source_handler the host
// gets every drag a page starts, instead of an AppKit drag session from its
// never-shown page window; it sends the drag to cmux as one DRAG_START, and
// cmux's page view starts the NSDraggingSession. Chrome splits a drag the same
// way: its browser process sends StartDrag to the app shim's view
// (content/common/web_contents_ns_view_bridge.mojom), which starts the session
// (content/app_shim_remote_cocoa/web_contents_view_cocoa.mm,
// -startDragWithDropData:) and reports its end back (EndDrag).
//
// Wire, next to kOpTextInputWatch (host_text_input.h); not in the generated op table:
//   cmux -> host  kOpDragSourceWatch  i32 installed (1 on, 0 off): the host sets
//                                     or clears its handler in the fork. Sent by
//                                     the remote shim's local
//                                     cmux_shim_set_drag_source_handler (014b).
//   host -> cmux  kOpDragStart        EncodeDragStart's fields; the remote shim
//                                     gives the handler ForkViewOf(the decoded
//                                     drag). The image and the file go in shared
//                                     memory past 64 KiB (task 020).
// cmux ends each drag with cmux_shim_browser_drag_source_ended (a generated
// post). A drag the host cannot send, or one that reaches cmux with no handler,
// ends at once with no operation: the fork starts no other drag until it ends.
//
// No CEF and no AppKit, header only: the host (host_dispatch.mm) and the remote
// shim (client/remote_shim.mm) both include it, and
// scripts/cmux-next/tests/chromium-host-dispatch.test.sh compiles it on Linux.
#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "chromium_host_tlv.h"

namespace cmux_host {

inline constexpr uint16_t kOpDragSourceWatch = 0x800c;
inline constexpr uint16_t kOpDragStart = 0x800d;

// The most bytes of a dragged file and of a drag image that go to cmux. A
// larger file goes without its contents (the drag keeps its URL and text); a
// larger image goes without the image. Both fit control::kMaxSharedBytes.
inline constexpr size_t kMaxDragFileBytes = 64 * 1024 * 1024;
inline constexpr size_t kMaxDragImageBytes = 16 * 1024 * 1024;

// The fork's cmux_drag_source_t (include/cef_cmux.h, API 30). Strings are
// UTF-8, "" when absent; byte pointers may be NULL. Fields are only appended;
// `size` is the fork's sizeof. cmux reads the same layout
// (CEFPageDragData.swift, `Offset`): chromium-host-dispatch.test.sh compares
// the offsets below with it.
struct ForkDragSource {
  int size;
  int allowed_operations;  // NSDragOperation bits: 1 copy, 2 link, 16 move
  const char* url;
  const char* url_title;
  const char* text;
  const char* html;
  const char* html_base_url;
  const uint8_t* file_contents;
  int file_contents_length;
  const char* file_name;
  const char* file_contents_source_url;
  const char* download_metadata;  // "mime:name:url" (DataTransfer "DownloadURL")
  const uint8_t* image_png;  // the drag image, `image_scale` pixels per DIP
  int image_png_length;
  double image_scale;
  int cursor_offset_x;  // the pointer's offset from the image's top left, DIP
  int cursor_offset_y;
};
static_assert(sizeof(void*) != 8 || sizeof(ForkDragSource) == 120, "the fork's API 30 layout on LP64");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, allowed_operations) == 4, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, url) == 8, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, url_title) == 16, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, text) == 24, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, html) == 32, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, html_base_url) == 40, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, file_contents) == 48, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, file_contents_length) == 56, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, file_name) == 64, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, file_contents_source_url) == 72, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, download_metadata) == 80, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, image_png) == 88, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, image_png_length) == 96, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, image_scale) == 104, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, cursor_offset_x) == 112, "LP64 offset");
static_assert(sizeof(void*) != 8 || offsetof(ForkDragSource, cursor_offset_y) == 116, "LP64 offset");

// A page's drag, owning its bytes.
struct DragSource {
  int32_t allowed_operations = 0;
  std::string url;
  std::string url_title;
  std::string text;
  std::string html;
  std::string html_base_url;
  std::string file_contents;
  std::string file_name;
  std::string file_contents_source_url;
  std::string download_metadata;
  std::string image_png;
  double image_scale = 1;
  int32_t cursor_offset_x = 0;
  int32_t cursor_offset_y = 0;

  bool operator==(const DragSource& other) const = default;
};

namespace drag_detail {

inline std::string Text(const char* text) {
  return text ? std::string(text) : std::string();
}

// `length` bytes at `data`, none when the pointer, the length or the bound is off.
inline std::string Bytes(const uint8_t* data, int length, size_t limit) {
  if (data == nullptr || length <= 0 || static_cast<size_t>(length) > limit) return std::string();
  return std::string(reinterpret_cast<const char*>(data), static_cast<size_t>(length));
}

inline double Scale(double scale) {
  return std::isfinite(scale) && scale > 0 ? scale : 1;
}

}  // namespace drag_detail

// The drag behind the fork's pointer; false (out untouched) for a struct older
// than API 30's. A file or image over its bound is left out.
inline bool ReadForkDragSource(const void* fork_drag, DragSource* out) {
  if (fork_drag == nullptr) return false;
  const auto* fork = static_cast<const ForkDragSource*>(fork_drag);
  if (fork->size < static_cast<int>(sizeof(ForkDragSource))) return false;
  DragSource drag;
  drag.allowed_operations = fork->allowed_operations;
  drag.url = drag_detail::Text(fork->url);
  drag.url_title = drag_detail::Text(fork->url_title);
  drag.text = drag_detail::Text(fork->text);
  drag.html = drag_detail::Text(fork->html);
  drag.html_base_url = drag_detail::Text(fork->html_base_url);
  drag.file_contents = drag_detail::Bytes(fork->file_contents, fork->file_contents_length, kMaxDragFileBytes);
  drag.file_name = drag_detail::Text(fork->file_name);
  drag.file_contents_source_url = drag_detail::Text(fork->file_contents_source_url);
  drag.download_metadata = drag_detail::Text(fork->download_metadata);
  drag.image_png = drag_detail::Bytes(fork->image_png, fork->image_png_length, kMaxDragImageBytes);
  drag.image_scale = drag_detail::Scale(fork->image_scale);
  drag.cursor_offset_x = fork->cursor_offset_x;
  drag.cursor_offset_y = fork->cursor_offset_y;
  *out = std::move(drag);
  return true;
}

// kOpDragStart's fields: i32 browser, i32 allowed operations; bytes url, url
// title, text, html, html base url, file contents, file name, file source url,
// download metadata, image PNG; f64 image scale; i32 cursor offset x, y. Text
// goes as bytes, so no UTF-8 check refuses a page's string.
inline std::vector<control::Field> EncodeDragStart(int32_t browser, const DragSource& drag) {
  control::TlvWriter w;
  w.I32(browser);
  w.I32(drag.allowed_operations);
  for (const std::string* bytes : {&drag.url, &drag.url_title, &drag.text, &drag.html, &drag.html_base_url,
                                   &drag.file_contents, &drag.file_name, &drag.file_contents_source_url,
                                   &drag.download_metadata, &drag.image_png}) {
    w.Bytes(bytes->data(), bytes->size());
  }
  w.F64(drag.image_scale);
  w.I32(drag.cursor_offset_x);
  w.I32(drag.cursor_offset_y);
  return w.Take();
}

// False for fields that are not EncodeDragStart's, or over its bounds.
inline bool DecodeDragStart(std::vector<control::Field> fields, int32_t* browser, DragSource* out) {
  control::TlvReader r(std::move(fields));
  DragSource drag;
  const int32_t id = r.I32();
  drag.allowed_operations = r.I32();
  for (std::string* bytes : {&drag.url, &drag.url_title, &drag.text, &drag.html, &drag.html_base_url,
                             &drag.file_contents, &drag.file_name, &drag.file_contents_source_url,
                             &drag.download_metadata, &drag.image_png}) {
    *bytes = r.Bytes();
  }
  drag.image_scale = r.F64();
  drag.cursor_offset_x = r.I32();
  drag.cursor_offset_y = r.I32();
  if (!r.ok() || !r.AtEnd() || drag.file_contents.size() > kMaxDragFileBytes ||
      drag.image_png.size() > kMaxDragImageBytes || drag_detail::Scale(drag.image_scale) != drag.image_scale) {
    return false;
  }
  *browser = id;
  *out = std::move(drag);
  return true;
}

// The fork's struct over `drag`'s storage, for a handler that reads
// cmux_drag_source_t (the remote shim); valid while `drag` lives unchanged.
// A string with a NUL byte reads up to it, as the fork's own C strings do.
inline ForkDragSource ForkViewOf(const DragSource& drag) {
  ForkDragSource view{};
  view.size = static_cast<int>(sizeof(ForkDragSource));
  view.allowed_operations = drag.allowed_operations;
  view.url = drag.url.c_str();
  view.url_title = drag.url_title.c_str();
  view.text = drag.text.c_str();
  view.html = drag.html.c_str();
  view.html_base_url = drag.html_base_url.c_str();
  view.file_contents = drag.file_contents.empty() ? nullptr : reinterpret_cast<const uint8_t*>(drag.file_contents.data());
  view.file_contents_length = static_cast<int>(drag.file_contents.size());
  view.file_name = drag.file_name.c_str();
  view.file_contents_source_url = drag.file_contents_source_url.c_str();
  view.download_metadata = drag.download_metadata.c_str();
  view.image_png = drag.image_png.empty() ? nullptr : reinterpret_cast<const uint8_t*>(drag.image_png.data());
  view.image_png_length = static_cast<int>(drag.image_png.size());
  view.image_scale = drag.image_scale;
  view.cursor_offset_x = drag.cursor_offset_x;
  view.cursor_offset_y = drag.cursor_offset_y;
  return view;
}

}  // namespace cmux_host
