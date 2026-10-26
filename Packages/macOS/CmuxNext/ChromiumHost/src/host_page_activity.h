// The Chromium Host's App Nap (plans/cmux-next/chrome-parity/p14-energy.md,
// task 128). The host's page windows are never ordered in (HostPageViews), so
// to macOS the host is an app with nothing on screen, and App Nap may throttle
// it while it draws a page cmux shows. Chrome's renderer holds an activity
// only while it is foregrounded and lets App Nap apply when it is backgrounded
// (content/common/mac/app_nap_activity.mm, AppNapActivity::Begin and End:
// NSActivityUserInitiatedAllowingIdleSystemSleep). The host does the same
// with what cmux shows: it holds that activity while one page or more is
// shown (CMUX_SHIM_PAGE_VISIBLE, the value cmux posts per page with
// cmux_shim_browser_set_page_visibility) and drops it when every page is
// hidden or occluded, so a host with no page on screen naps. HostContext
// counts the shown pages from those posts, the one record of what cmux
// shows, and hands the count here on each change.
//
// The activity is held from the host's start until the first count after
// initialize (HostContext::Resume): cmux starts a host for a page it is about
// to show, and Chromium's start should not run napped.
//
// Plain C++, no AppKit: browser_host_main.mm passes the NSProcessInfo calls,
// and the tests a recorder (scripts/cmux-next/tests/chromium-host-dispatch.test.sh).
// Main thread only, like HostContext.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <utility>

namespace cmux_host {

class PageShowActivity {
 public:
  // Begins the activity (true) or ends it (false); called only on a change.
  using Hold = std::function<void(bool held)>;

  // Begins the activity: the host starts held.
  explicit PageShowActivity(Hold hold) : hold_(std::move(hold)) { Set(true); }
  PageShowActivity(const PageShowActivity&) = delete;
  PageShowActivity& operator=(const PageShowActivity&) = delete;

  // `shown` pages are on screen: held while it is above 0. The same answer
  // again changes nothing.
  void SetShownPages(size_t shown) { Set(shown > 0); }

  bool held() const { return held_; }
  // Begins and ends so far, the start's begin included.
  uint64_t edges() const { return edges_; }

 private:
  void Set(bool held) {
    if (edges_ > 0 && held == held_) return;
    held_ = held;
    ++edges_;
    if (hold_) hold_(held);
  }

  Hold hold_;
  bool held_ = false;
  uint64_t edges_ = 0;
};

}  // namespace cmux_host
