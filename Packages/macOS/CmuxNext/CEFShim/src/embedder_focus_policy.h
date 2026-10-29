// Which page may take focus when no focus_request_fn is installed: the
// Chromium Host's mode. cmux installs no focus handler
// there; it marks each page its window's first responder shows embedder-active
// (cmux_shim_browser_set_embedder_active, fork API 30), and only a marked page
// may be focused, by cmux or by Chromium's own request after a navigation it
// started. Every other page's request is refused, so a navigation in a
// background pane never takes the focus. The mark is per browser, as in the
// fork: cmux has one first responder per window, so two windows can each show
// a marked page. Chrome's rule is the same: each window's active tab is
// focused (BrowserView::OnActiveTabChanged in
// chrome/browser/ui/views/frame/browser_view.cc restores the focus of the tab
// that becomes active), window activation decides which one has the keys, and
// a load in a background tab focuses nothing. No CEF dependency, so the test
// compiles it alone (scripts/cmux-next/test-shim-embedder-focus-cpp.sh).
#ifndef CMUX_SHIM_EMBEDDER_FOCUS_POLICY_H_
#define CMUX_SHIM_EMBEDDER_FOCUS_POLICY_H_

#include <cstddef>
#include <unordered_set>

namespace cmux_shim {

class EmbedderFocusPolicy {
 public:
  // cmux_shim_focus_request_fn (cmux_cef_shim.h): returns 0 to refuse.
  using FocusRequestFn = int (*)(void* ctx, int browser_id, int source);

  // cmux marked `browser_id` active (its page view is its window's first
  // responder) or inactive (it resigned, or the pane shows another tab).
  void SetActive(int browser_id, bool active) {
    if (browser_id <= 0) return;
    if (active) {
      active_.insert(browser_id);
    } else {
      active_.erase(browser_id);
    }
  }

  // The browser is gone (OnBeforeClose).
  void Forget(int browser_id) { active_.erase(browser_id); }

  // True when a request to focus `browser_id` may go on.
  bool Allows(int browser_id) const { return active_.count(browser_id) != 0; }

  // CefFocusHandler::OnSetFocus's answer (true cancels the request): an
  // installed `handler` (in process) decides; with none (host mode) only a
  // marked page may take focus.
  bool Refuses(FocusRequestFn handler, void* ctx, int browser_id, int source) const {
    if (handler) return handler(ctx, browser_id, source) == 0;
    return !Allows(browser_id);
  }

  size_t active_count() const { return active_.size(); }

 private:
  std::unordered_set<int> active_;
};

}  // namespace cmux_shim

#endif  // CMUX_SHIM_EMBEDDER_FOCUS_POLICY_H_
