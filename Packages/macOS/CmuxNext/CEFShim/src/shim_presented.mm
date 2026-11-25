// Presented pages (cmux's InTreePages.Presentation.presented; plans/cmux-next/cef-helper-app-DESIGN.md 3.3, 3.7 and
// 4, in process): the page window is detached (fork API 30) from its attach on, so the WindowServer sends it no
// mouse or keys and it is never key. cmux's own page view is the page's input surface and forwards here; page
// focus is cmux's value (cmux_browser_set_embedder_active) plus a focus of the page's web view that activates no
// window. UI thread only; each returns 0 for an unknown browser.

#include "page_input.h"
#include "shim_internal.h"

#include "include/views/cef_browser_view.h"

using namespace cmux_shim;

extern "C" {

int cmux_shim_browser_send_mouse(int browser_id, int x, int y, int phase, int button, int click_count, int buttons,
                                 uint64_t modifier_flags) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  if (!browser) return 0;
  cmux_page_input::SendMouse(browser->GetHost(), x, y, phase, button, click_count, buttons, modifier_flags);
  return 1;
}

int cmux_shim_browser_send_key(int browser_id, int phase, int key_code, int character, int unmodified_character,
                               uint64_t modifier_flags, int repeat) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  if (!browser) return 0;
  cmux_page_input::SendKey(browser->GetHost(), phase, key_code, static_cast<uint16_t>(character),
                           static_cast<uint16_t>(unmodified_character), modifier_flags, repeat != 0);
  return 1;
}

int cmux_shim_browser_edit(int browser_id, int command) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  if (!browser) return 0;
  cmux_page_input::Edit(browser, command);
  return 1;
}

int cmux_shim_browser_set_page_focus(int browser_id, int focus) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  if (!browser) return 0;
  // The detached page window's key state (focus rings, caret, document.hasFocus(), the Browser's active state):
  // no AppKit key change. Chromium's views activation then restores the page's stored focused view.
  int active = fork_api().browser_set_embedder_active ? fork_api().browser_set_embedder_active(browser_id, focus ? 1 : 0)
                                                     : 0;
  if (focus) {
    // The page's web view takes the focus inside its own (headless) window. Never CefBrowserHost::SetFocus: on
    // macOS it activates the page's widget first, which made the headless window AppKit's key window (in-tree
    // sweep-06675353 D1, design 3.7).
    if (CefRefPtr<CefBrowserView> view = CefBrowserView::GetForBrowser(browser)) {
      view->RequestFocus();
      return 1;
    }
  }
  return active;
}

void cmux_shim_set_cursor_handler(cmux_shim_cursor_fn handler) {
  host().cursor = handler;
}

}  // extern "C"
