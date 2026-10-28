// When CMUX_SHIM_FRAME_RENDERERS (cmux_cef_shim.h) goes out, with no CEF
// (scripts/cmux-next/tests/shim-frame-renderers.test.sh compiles it alone).
//
// CEF reports each frame's link to its renderer (CefFrameHandler: OnFrameAttached, OnFrameDetached,
// OnMainFrameChanged), which follows the frame changes Chrome's task manager uses to list a tab's
// processes (RenderFrameCreated, RenderFrameDeleted and RenderFrameHostChanged in
// chrome/browser/task_manager/providers/web_contents/web_contents_task_provider.cc). A page that adds
// ten iframes attaches ten frames in one task, so the shim checks the browser's renderers once, in a
// task posted at the first change, and reports only a new set: cmux's tab.renderer_client_ids mirror
// is pushed once per change.
//
// UI thread only: no lock.
#pragma once

#include <algorithm>
#include <map>
#include <set>
#include <utility>
#include <vector>

namespace cmux_shim {

class FrameRenderers {
 public:
  // A frame of `browser` attached, detached or became its main frame. True when the caller posts the
  // check: none is pending for the browser yet.
  bool Changed(int browser) { return pending_.insert(browser).second; }

  // The posted check, with the renderer client id of each of the browser's frames now (0 for a frame
  // with none). True when their distinct set is not the one last reported (the first check always
  // reports); it becomes the reported one.
  bool Check(int browser, const std::vector<int>& clients) {
    pending_.erase(browser);
    std::vector<int> renderers;
    for (const int id : clients) {
      if (id > 0) renderers.push_back(id);
    }
    std::sort(renderers.begin(), renderers.end());
    renderers.erase(std::unique(renderers.begin(), renderers.end()), renderers.end());
    auto [at, first] = reported_.try_emplace(browser, renderers);
    if (first) return true;
    if (at->second == renderers) return false;
    at->second = std::move(renderers);
    return true;
  }

  // The browser closed: bounded by the live browsers.
  void Forget(int browser) {
    pending_.erase(browser);
    reported_.erase(browser);
  }

  bool Pending(int browser) const { return pending_.count(browser) > 0; }
  size_t size() const { return reported_.size(); }

 private:
  std::set<int> pending_;
  std::map<int, std::vector<int>> reported_;
};

}  // namespace cmux_shim
