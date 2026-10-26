// Which page may take focus when no focus_request_fn is installed: the
// Chromium Host's mode (task p01-process-032). cmux installs no focus handler
// there; it marks the page its first responder shows embedder-active
// (cmux_shim_browser_set_embedder_active, fork API 30), and that page alone
// may be focused, by cmux or by Chromium's own request after a navigation it
// started. Every other page's request is refused, so a navigation in a
// background pane never takes the focus. Chrome's rule is the same: only a
// window's active tab is ever focused (BrowserView::OnActiveTabChanged in
// chrome/browser/ui/views/frame/browser_view.cc restores the focus of the tab
// that becomes active), and a load in a background tab focuses nothing. No
// CEF dependency, so the test compiles it alone
// (scripts/cmux-next/test-shim-embedder-focus-cpp.sh).
#ifndef CMUX_SHIM_EMBEDDER_FOCUS_POLICY_H_
#define CMUX_SHIM_EMBEDDER_FOCUS_POLICY_H_

namespace cmux_shim {

class EmbedderFocusPolicy {
 public:
  // cmux marked `browser_id` active (its page view is first responder) or
  // inactive. Marking a page active makes it the only one: cmux has one first
  // responder. Marking a page inactive that is not the active one changes
  // nothing (a late blur of the page that had focus before).
  void SetActive(int browser_id, bool active) {
    if (active) {
      active_ = browser_id > 0 ? browser_id : 0;
    } else if (browser_id == active_) {
      active_ = 0;
    }
  }

  // The browser is gone (OnBeforeClose).
  void Forget(int browser_id) {
    if (browser_id == active_) active_ = 0;
  }

  // True when a request to focus `browser_id` may go on.
  bool Allows(int browser_id) const { return browser_id > 0 && browser_id == active_; }

  int active() const { return active_; }

 private:
  int active_ = 0;
};

}  // namespace cmux_shim

#endif  // CMUX_SHIM_EMBEDDER_FOCUS_POLICY_H_
