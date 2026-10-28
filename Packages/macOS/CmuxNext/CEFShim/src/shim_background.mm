// Page background color (cmux_shim_set_background_color and
// cmux_shim_browser_set_background_color): the theme color new browsers
// start with, and the browsers that set a background of their own.
// cmux_shim_tab_set_transparent_background: see-through pages (fork API 17).
// UI thread only.

#include <set>

#include "shim_internal.h"

namespace cmux_shim {

static cef_color_t g_background_color = 0;

cef_color_t BackgroundColor() {
  return g_background_color;
}

std::set<int>& own_background_browsers() {
  static std::set<int> set;
  return set;
}

void ForgetOwnBackground(int browser_id) {
  own_background_browsers().erase(browser_id);
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

void cmux_shim_set_background_color(unsigned int argb) {
  const bool changed = g_background_color != static_cast<cef_color_t>(argb);
  g_background_color = static_cast<cef_color_t>(argb);
  // Fork API 12: live tabs still on the theme color follow a theme change;
  // tabs past their first real page keep their own (white) background.
  if (changed && argb && fork_api().browser_set_background_color) {
    for (auto& [id, browser] : browsers()) {
      if (own_background_browsers().count(id)) continue;
      fork_api().browser_set_background_color(id, argb);
    }
  }
}

int cmux_shim_browser_set_background_color(int browser_id, unsigned int argb) {
  if (!fork_api().browser_set_background_color) return 0;
  own_background_browsers().insert(browser_id);
  fork_api().browser_set_background_color(browser_id, argb);
  return 1;
}

int cmux_shim_tab_set_transparent_background(int browser_id, int transparent) {
  if (!fork_api().tab_set_transparent_background) return 0;
  return fork_api().tab_set_transparent_background(browser_id, transparent ? 1 : 0);
}

unsigned int cmux_shim_browser_set_layer_hosting(int browser_id, int enabled) {
  if (!fork_api().browser_set_layer_hosting) return 0;
  return fork_api().browser_set_layer_hosting(browser_id, enabled ? 1 : 0);
}

int cmux_shim_browser_set_resize_sync(int browser_id, int timeout_ms) {
  if (!fork_api().browser_set_resize_sync) return 0;
  return fork_api().browser_set_resize_sync(browser_id, timeout_ms);
}

}  // extern "C"
