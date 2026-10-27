// The numbers of a CMUX_SHIM_CURSOR event (cmux_cef_shim.h), with no CEF
// (scripts/cmux-next/test-shim-cursor-cpp.sh compiles it alone).
//
// Chromium's renderer reports the page's cursor to the browser process
// (RenderWidgetHostImpl::SetCursor), which hands it to the view that shows the
// page: on macOS RenderWidgetHostViewMac::DisplayCursor, over remote cocoa to
// the app shim's RenderWidgetHostViewCocoa
// (content/app_shim_remote_cocoa/render_widget_host_ns_view_bridge.mm). In the
// Chromium Host that view is cmux's ChromiumHostPageView, so the cursor is
// data on the wire: its type, and for a CSS cursor image the image (PNG), its
// scale and its hotspot, as ui::Cursor carries them.
#pragma once

#include <cstdint>

namespace cmux_shim {

// cef_cursor_type_t's CT_POINTER and CT_CUSTOM (include/internal/cef_types.h,
// the order of ui::mojom::CursorType).
inline constexpr int64_t kCursorPointer = 0;
inline constexpr int64_t kCursorCustom = 45;

// The largest custom image side, in pixels: blink's 128-DIP cursor limit
// (EventHandler's kMaximumCursorSize) at a device scale of up to 8.
inline constexpr int kMaxCustomCursorSide = 1024;

// The image of a CT_CUSTOM cursor as the event carries it.
struct CustomCursorFields {
  int32_t scale_milli;  // the event's request: image pixels per DIP x 1000
  int64_t hotspot;      // the event's b: x in the low 32 bits, y in the high 32
};

// True when a custom image of this size may go on the wire: not empty, no
// side over kMaxCustomCursorSide, and the BGRA bytes CEF hands over match.
inline bool CustomCursorAllowed(int width, int height, const void* pixels) {
  return pixels != nullptr && width > 0 && height > 0 && width <= kMaxCustomCursorSide &&
         height <= kMaxCustomCursorSide;
}

// The event's request and b for a custom image. A scale that is not a finite
// positive number counts as 1, as Chrome's CreateCustomCursor does with 0
// (ui/base/cocoa/cursor_utils.mm). The hotspot is clamped into the image.
inline CustomCursorFields CustomCursorFieldsFor(float scale, int hotspot_x, int hotspot_y, int width, int height) {
  const bool usable = scale > 0 && scale <= 16;  // false for NaN too
  const int32_t milli = usable ? static_cast<int32_t>(scale * 1000.0f + 0.5f) : 1000;
  auto clamp = [](int value, int side) { return value < 0 ? 0 : (value >= side ? side - 1 : value); };
  const uint32_t x = static_cast<uint32_t>(clamp(hotspot_x, width));
  const uint32_t y = static_cast<uint32_t>(clamp(hotspot_y, height));
  return {milli, static_cast<int64_t>((static_cast<uint64_t>(y) << 32) | x)};
}

}  // namespace cmux_shim
