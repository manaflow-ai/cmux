// <select> popups as data (fork API 31, task p01-process-171; cmux task
// p01-process-060), with no CEF (scripts/cmux-next/test-shim-popup-menu-cpp.sh
// compiles it alone): the shim's copies of include/cef_cmux.h's
// cmux_popup_menu_t and cmux_popup_menu_item_t (manaflow-ai/cef
// cp/p01-process-171; the artifact's header is older than API 31) and the
// CMUX_SHIM_POPUP_MENU event's JSON. Chrome's browser process hands the same
// fields to the view that shows the menu (RenderWidgetHostNSView's
// DisplayPopupMenu, content/common/render_widget_host_ns_view.mojom), which
// builds its NSMenu from them (content/app_shim_remote_cocoa/web_menu_runner_mac.mm).
#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>

#include "unsafe_buffers.h"

namespace cmux_shim {

// cef_cmux.h's cmux_popup_menu_item_t. Strings are UTF-8, "" when absent.
struct ForkPopupMenuItem {
  const char* label;
  const char* tool_tip;
  int type;  // CMUX_POPUP_MENU_ITEM_*: 0 option, 1 checkable, 2 group, 3 separator, 4 submenu
  int enabled;
  int checked;
  int rtl;
  int direction_override;
};

// cef_cmux.h's cmux_popup_menu_t (fields are only appended; `size` is the
// fork's sizeof).
struct ForkPopupMenu {
  int size;
  int64_t token;
  int x;
  int y;
  int width;
  int height;
  double font_size;
  int selected;
  int right_aligned;
  const ForkPopupMenuItem* items;
  int item_count;
};

// cef_cmux.h's cmux_popup_menu_fn and cmux_popup_menu_hide_fn.
using ForkPopupMenuShowFn = void (*)(void* context, int browser_id, const ForkPopupMenu* menu);
using ForkPopupMenuHideFn = void (*)(void* context, int browser_id, int64_t token);

// The fork's struct has every field this shim reads, and its items are there.
inline bool PopupMenuReadable(const ForkPopupMenu& menu) {
  return menu.size >= static_cast<int>(sizeof(ForkPopupMenu)) && menu.item_count >= 0 &&
         (menu.item_count == 0 || menu.items != nullptr);
}

// The length of the valid UTF-8 sequence at the start of `s` (not empty), 0
// when it is not one: an overlong form, a surrogate, past U+10FFFF or cut.
inline size_t Utf8SequenceLength(std::string_view s) {
  auto byte = [s](size_t i) { return static_cast<unsigned char>(s[i]); };
  const unsigned char c = byte(0);
  if (c < 0x80) return 1;
  size_t length = 0;
  unsigned char low = 0x80, high = 0xbf;  // the second byte's range
  if (c >= 0xc2 && c <= 0xdf) {
    length = 2;
  } else if (c >= 0xe0 && c <= 0xef) {
    length = 3;
    if (c == 0xe0) low = 0xa0;
    if (c == 0xed) high = 0x9f;
  } else if (c >= 0xf0 && c <= 0xf4) {
    length = 4;
    if (c == 0xf0) low = 0x90;
    if (c == 0xf4) high = 0x8f;
  } else {
    return 0;
  }
  if (s.size() < length || byte(1) < low || byte(1) > high) return 0;
  for (size_t i = 2; i < length; ++i) {
    if ((byte(i) & 0xc0) != 0x80) return 0;
  }
  return length;
}

// `text` as a JSON string. The control channel ends the connection on bad
// UTF-8 (chromium_host_control.h), so a byte that starts no valid sequence
// becomes U+FFFD, as Chromium's own UTF-8 conversions do.
inline void AppendJsonString(std::string& out, const char* text) {
  constexpr std::string_view kHex = "0123456789abcdef";
  out += '"';
  std::string_view rest(text ? text : "");
  while (!rest.empty()) {
    const unsigned char c = static_cast<unsigned char>(rest.front());
    size_t consumed = 1;
    if (c == '"' || c == '\\') {
      out += '\\';
      out += static_cast<char>(c);
    } else if (c < 0x20) {
      out += "\\u00";
      out += kHex[c >> 4];
      out += kHex[c & 0xf];
    } else if (c >= 0x80) {
      const size_t length = Utf8SequenceLength(rest);
      if (length == 0) {
        out += "\xef\xbf\xbd";
      } else {
        out += rest.substr(0, length);
        consumed = length;
      }
    } else {
      out += static_cast<char>(c);
    }
    rest.remove_prefix(consumed);
  }
  out += '"';
}

// The largest font size a popup's JSON carries, in points.
inline constexpr double kMaxPopupMenuFontSize = 10000;

// CMUX_SHIM_POPUP_MENU's s1 (cmux_cef_shim.h): the rect, font size,
// selection, alignment and items of a readable menu (PopupMenuReadable).
inline std::string PopupMenuJson(const ForkPopupMenu& menu) {
  auto flag = [](int value) { return value ? "true" : "false"; };
  auto number = [](long long value) { return std::to_string(value); };
  std::string out;
  out.reserve(96 + static_cast<size_t>(menu.item_count) * 112);
  // Thousandths of a point, written with integers: %f follows the process's
  // LC_NUMERIC, and JSON has no NaN or infinity. A size Chromium never sends
  // (not above 0, not finite, over kMaxPopupMenuFontSize) reads as 0, the
  // menu's own font.
  const double size = menu.font_size;
  const long long milli = std::isfinite(size) && size > 0 && size <= kMaxPopupMenuFontSize ? std::llround(size * 1000) : 0;
  const std::string thousandths = number(milli % 1000);
  out += "{\"x\":" + number(menu.x) + ",\"y\":" + number(menu.y) + ",\"width\":" + number(menu.width) +
         ",\"height\":" + number(menu.height) + ",\"fontSize\":" + number(milli / 1000) + "." +
         std::string(3 - thousandths.size(), '0') + thousandths + ",\"selected\":" + number(menu.selected) +
         ",\"rightAligned\":" + flag(menu.right_aligned) + ",\"items\":[";
  // SAFETY: the menu is readable (PopupMenuReadable, this function's
  // precondition): the fork's `items` holds `item_count` items, alive for the
  // fork's show call that hands the menu over.
  const std::span<const ForkPopupMenuItem> items = UNSAFE_BUFFERS(SpanFromCArray(menu.items, menu.item_count));
  bool first = true;
  for (const ForkPopupMenuItem& item : items) {
    out += first ? "{\"label\":" : ",{\"label\":";
    first = false;
    AppendJsonString(out, item.label);
    out += ",\"toolTip\":";
    AppendJsonString(out, item.tool_tip);
    out += ",\"type\":" + number(item.type) + ",\"enabled\":" + flag(item.enabled) + ",\"checked\":" +
           flag(item.checked) + ",\"rtl\":" + flag(item.rtl) + ",\"directionOverride\":" +
           flag(item.direction_override) + "}";
  }
  out += "]}";
  return out;
}

}  // namespace cmux_shim
