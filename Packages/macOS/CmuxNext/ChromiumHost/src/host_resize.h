// A hosted page's resize, from cmux to the Chromium Host
// (plans/cmux-next/chrome-parity/p01-process.md 3.1).
//
// cmux resizes a page view in one main-thread turn; the page's Chromium
// window lives in the host. Each size change goes as kOpPageResize, an
// ordered op (task 092: geometry is on the one ordered stream, as
// OnBoundsInWindowChanged is on Chrome's RenderWidgetHostNSViewHost pipe):
//   i64 page view token, i32 width, i32 height (points)
// It has no token and is not answered.
//
// Plain C++, so the tests build it on Linux
// (scripts/cmux-next/tests/chromium-host-dispatch.test.sh).
#pragma once

#include <cstdint>
#include <optional>
#include <vector>

#include "chromium_host_tlv.h"

namespace cmux_host {

// Next to kOpGeometryStats (host_dispatch.h): not in the generated op table.
inline constexpr uint16_t kOpPageResize = 0x800a;

// kOpPageResize's fields.
struct PageResize {
  uint64_t view = 0;
  int32_t width = 0;
  int32_t height = 0;
};

// The op's fields; nullopt for a malformed op (wrong types, extra fields, a
// view token 0, a size under 1 point or over 32,767).
inline std::optional<PageResize> DecodePageResize(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  PageResize resize;
  resize.view = r.View();
  resize.width = r.I32();
  resize.height = r.I32();
  constexpr int32_t kMaxSide = 32767;
  if (!r.ok() || !r.AtEnd() || resize.view == 0 || resize.width < 1 || resize.height < 1 ||
      resize.width > kMaxSide || resize.height > kMaxSide) {
    return std::nullopt;
  }
  return resize;
}

// Writes kOpPageResize's fields for `resize` (the remote shim's side).
inline void WritePageResize(const PageResize& resize, control::TlvWriter* w) {
  w->ViewToken(resize.view);
  w->I32(resize.width);
  w->I32(resize.height);
}

}  // namespace cmux_host
