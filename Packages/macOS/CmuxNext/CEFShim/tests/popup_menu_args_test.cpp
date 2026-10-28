// Checks the <select> popup's struct copies and its CMUX_SHIM_POPUP_MENU JSON
// (CEFShim/src/popup_menu_args.h, scripts/cmux-next/test-shim-popup-menu-cpp.sh).
#include <cmath>
#include <cstddef>
#include <iostream>
#include <limits>
#include <string>

#include "../src/popup_menu_args.h"

#ifdef CMUX_CHECK_FORK_HEADER
// With a fork checkout at API 31 (CMUX_CEF_FORK, see the script): the copies
// have include/cef_cmux.h's layouts.
#include <cstddef>
#include <type_traits>

#include "include/cef_cmux.h"

#define SAME(T, U)                                   \
  static_assert(sizeof(T) == sizeof(U), #T " size"); \
  static_assert(alignof(T) == alignof(U), #T " alignment")
#define FIELD(T, U, f) static_assert(offsetof(T, f) == offsetof(U, f), #T "." #f)
SAME(cmux_shim::ForkPopupMenuItem, cmux_popup_menu_item_t);
FIELD(cmux_shim::ForkPopupMenuItem, cmux_popup_menu_item_t, label);
FIELD(cmux_shim::ForkPopupMenuItem, cmux_popup_menu_item_t, tool_tip);
FIELD(cmux_shim::ForkPopupMenuItem, cmux_popup_menu_item_t, type);
FIELD(cmux_shim::ForkPopupMenuItem, cmux_popup_menu_item_t, enabled);
FIELD(cmux_shim::ForkPopupMenuItem, cmux_popup_menu_item_t, checked);
FIELD(cmux_shim::ForkPopupMenuItem, cmux_popup_menu_item_t, rtl);
FIELD(cmux_shim::ForkPopupMenuItem, cmux_popup_menu_item_t, direction_override);
SAME(cmux_shim::ForkPopupMenu, cmux_popup_menu_t);
FIELD(cmux_shim::ForkPopupMenu, cmux_popup_menu_t, size);
FIELD(cmux_shim::ForkPopupMenu, cmux_popup_menu_t, token);
FIELD(cmux_shim::ForkPopupMenu, cmux_popup_menu_t, x);
FIELD(cmux_shim::ForkPopupMenu, cmux_popup_menu_t, y);
FIELD(cmux_shim::ForkPopupMenu, cmux_popup_menu_t, width);
FIELD(cmux_shim::ForkPopupMenu, cmux_popup_menu_t, height);
FIELD(cmux_shim::ForkPopupMenu, cmux_popup_menu_t, font_size);
FIELD(cmux_shim::ForkPopupMenu, cmux_popup_menu_t, selected);
FIELD(cmux_shim::ForkPopupMenu, cmux_popup_menu_t, right_aligned);
FIELD(cmux_shim::ForkPopupMenu, cmux_popup_menu_t, items);
FIELD(cmux_shim::ForkPopupMenu, cmux_popup_menu_t, item_count);
static_assert(std::is_same_v<cmux_shim::ForkPopupMenuHideFn, cmux_popup_menu_hide_fn>, "cmux_popup_menu_hide_fn");
static_assert(CMUX_POPUP_MENU_ITEM_OPTION == 0 && CMUX_POPUP_MENU_ITEM_CHECKABLE == 1 &&
                  CMUX_POPUP_MENU_ITEM_GROUP == 2 && CMUX_POPUP_MENU_ITEM_SEPARATOR == 3 &&
                  CMUX_POPUP_MENU_ITEM_SUBMENU == 4,
              "the item kinds the JSON carries as numbers");
#endif

using cmux_shim::ForkPopupMenu;
using cmux_shim::ForkPopupMenuItem;
using cmux_shim::PopupMenuJson;
using cmux_shim::PopupMenuReadable;

static int g_cases = 0;
static int g_failures = 0;

static void Expect(bool ok, const char* what) {
  ++g_cases;
  if (!ok) {
    ++g_failures;
    std::cerr << "FAIL " << what << "\n";
  }
}

static void ExpectEqual(const std::string& got, const std::string& want, const char* what) {
  Expect(got == want, what);
  if (got != want) std::cerr << "  got  " << got << "\n  want " << want << "\n";
}

static ForkPopupMenu Menu(const ForkPopupMenuItem* items, int count) {
  ForkPopupMenu menu{};
  menu.size = sizeof(ForkPopupMenu);
  menu.token = 9007199254740993;  // past 2^53: the token rides in the event's int64, not the JSON
  menu.x = 40;
  menu.y = -12;
  menu.width = 240;
  menu.height = 32;
  menu.font_size = 13.5;
  menu.selected = 1;
  menu.right_aligned = 0;
  menu.items = items;
  menu.item_count = count;
  return menu;
}

static void Readable() {
  const ForkPopupMenuItem item{"a", "", 0, 1, 0, 0, 0};
  ForkPopupMenu menu = Menu(&item, 1);
  Expect(PopupMenuReadable(menu), "the fork's struct of this size is read");
  menu.size = sizeof(ForkPopupMenu) + 16;
  Expect(PopupMenuReadable(menu), "a newer fork's longer struct is read (fields are only appended)");
  menu.size = static_cast<int>(offsetof(ForkPopupMenu, item_count));
  Expect(!PopupMenuReadable(menu), "an older, shorter struct is refused");
  menu = Menu(nullptr, 2);
  Expect(!PopupMenuReadable(menu), "a count with no items is refused");
  menu = Menu(nullptr, 0);
  Expect(PopupMenuReadable(menu), "an empty popup is read");
  menu = Menu(&item, -1);
  Expect(!PopupMenuReadable(menu), "a negative count is refused");
}

static void Json() {
  const ForkPopupMenuItem items[] = {
      {"Fruit", "", 2, 1, 0, 0, 0},
      {"Apple", "a \"red\" one\\", 0, 1, 0, 0, 0},
      {"", nullptr, 3, 1, 0, 0, 0},
      {"\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d", "tab\there\nnew", 1, 0, 1, 1, 1},
  };
  ExpectEqual(PopupMenuJson(Menu(items, 4)),
              "{\"x\":40,\"y\":-12,\"width\":240,\"height\":32,\"fontSize\":13.500,\"selected\":1,"
              "\"rightAligned\":false,\"items\":["
              "{\"label\":\"Fruit\",\"toolTip\":\"\",\"type\":2,\"enabled\":true,\"checked\":false,\"rtl\":false,"
              "\"directionOverride\":false},"
              "{\"label\":\"Apple\",\"toolTip\":\"a \\\"red\\\" one\\\\\",\"type\":0,\"enabled\":true,"
              "\"checked\":false,\"rtl\":false,\"directionOverride\":false},"
              "{\"label\":\"\",\"toolTip\":\"\",\"type\":3,\"enabled\":true,\"checked\":false,\"rtl\":false,"
              "\"directionOverride\":false},"
              "{\"label\":\"\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d\",\"toolTip\":\"tab\\u0009here\\u000anew\",\"type\":1,"
              "\"enabled\":false,\"checked\":true,\"rtl\":true,\"directionOverride\":true}]}",
              "every field, quotes, backslashes, controls escaped, UTF-8 kept, a NULL string empty");

  ForkPopupMenu empty = Menu(nullptr, 0);
  empty.right_aligned = 1;
  empty.selected = -1;
  empty.font_size = 16;
  ExpectEqual(PopupMenuJson(empty),
              "{\"x\":40,\"y\":-12,\"width\":240,\"height\":32,\"fontSize\":16.000,\"selected\":-1,"
              "\"rightAligned\":true,\"items\":[]}",
              "an empty right-aligned popup with no selection");

  for (double bad : {std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::infinity(), -3.0, 0.0,
                     1e300}) {
    ForkPopupMenu menu = Menu(nullptr, 0);
    menu.font_size = bad;
    Expect(PopupMenuJson(menu).find("\"fontSize\":0.000,") != std::string::npos,
           "a font size Chromium never sends reads as 0 and stays a JSON number");
  }
  ForkPopupMenu precise = Menu(nullptr, 0);
  precise.font_size = 13.3333;
  Expect(PopupMenuJson(precise).find("\"fontSize\":13.333,") != std::string::npos, "thousandths of a point");
}

static void Utf8() {
  // Bad bytes become U+FFFD; the control channel would end the connection on them.
  const char* cases[][2] = {
      {"a\xff" "b", "a\xef\xbf\xbd" "b"},                    // a byte that starts nothing
      {"\xc0\xaf", "\xef\xbf\xbd\xef\xbf\xbd"},                // an overlong '/'
      {"\xed\xa0\x80", "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd"},  // a UTF-16 surrogate
      {"\xf4\x90\x80\x80", "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd"},  // past U+10FFFF
      {"cut\xe2\x82", "cut\xef\xbf\xbd\xef\xbf\xbd"},          // a sequence cut by the end
      {"\xf0\x9f\x8d\x8e ok", "\xf0\x9f\x8d\x8e ok"},           // a 4-byte character is kept
  };
  for (const auto& c : cases) {
    std::string out;
    cmux_shim::AppendJsonString(out, c[0]);
    ExpectEqual(out, std::string("\"") + c[1] + "\"", "invalid UTF-8 is replaced, valid UTF-8 kept");
  }
}

int main() {
  Readable();
  Json();
  Utf8();
  if (g_failures) {
    std::cerr << g_failures << " of " << g_cases << " failed\n";
    return 1;
  }
  std::cout << "popup_menu_args: " << g_cases << " passed\n";
  return 0;
}
