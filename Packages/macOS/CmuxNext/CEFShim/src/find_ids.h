// The find id each browser's FIND_RESULT events carry: the caller's, as
// cmux_cef_shim.h promises (no CEF needed:
// scripts/cmux-next/tests/shim-find-ids.test.sh).
//
// CEF's OnFindResult reports Chromium's own find session id, which cmux never
// sees. The shim stamps each result with the find id of the browser's last
// cmux_shim_find instead. That id names the search the result belongs to:
// CefBrowserHost::Find starts the search inside cmux_shim_find on the UI
// thread, OnFindResult runs on the same thread, and from then on Chromium
// drops every reply of an older search (FindTabHelper::HandleFindReply,
// components/find_in_page/find_tab_helper.cc). A result cmux reads with an
// older id left before the newer search started (in host mode it was on the
// wire), and cmux drops it, as FindTabHelper does.
#pragma once

#include <cstddef>
#include <map>

namespace cmux_shim {

class FindIds {
 public:
  // cmux_shim_find(browser_id, find_id, ...) is starting a search.
  void Sent(int browser_id, int find_id) { ids_[browser_id] = find_id; }

  // The find id a FIND_RESULT of `browser_id` carries: its last search's, or 0
  // when cmux started none.
  int Of(int browser_id) const {
    auto found = ids_.find(browser_id);
    return found == ids_.end() ? 0 : found->second;
  }

  // The browser closed.
  void Forget(int browser_id) { ids_.erase(browser_id); }

  size_t size() const { return ids_.size(); }

 private:
  std::map<int, int> ids_;
};

}  // namespace cmux_shim
