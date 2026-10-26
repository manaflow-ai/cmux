// The ids the Chromium Host mints for the tabs Chromium opens for window requests (task 031 of
// plans/cmux-next/chrome-parity/p01-process.md). The host's shim decides each request with the policy
// cmux pushed and reports it (CMUX_SHIM_WINDOW_REQUEST_RESULT) before Chromium creates the tab: an
// INSERT gets an id of the host's range (chromium_host_mint.h) in that result, and the tab's own
// AFTER_CREATED binds it, so cmux adopts the tab under an id it already knows. Chrome's browser process
// names the new WebContents when the navigation places it (chrome/browser/ui/browser_navigator.cc,
// GetBrowserAndTabForDisposition), not when the tab strip reports it.
//
// A tab is matched to its request by the Chromium window the request inserts into, oldest first (the
// order cmux's placements use, CEFPlacementQueue), else, while the tab has no window yet, by its opener.
// An insert whose tab never comes (Chromium aborted it) waits until kMaxPending newer ones push it out.
//
// HostContext (host_dispatch.h) and ClientIds (host_client_ids.h) each own one. Header-only, no CEF.
// UI thread only, like every shim call: no lock (p01-process section 4, rule 1).
#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>

#include "chromium_host_mint.h"

namespace cmux_host {

class WindowRequestTabIds {
 public:
  static constexpr size_t kMaxPending = 4096;
  // cmux_shim_window_outcome_t's CMUX_SHIM_WINDOW_INSERT (this header does not include the shim's).
  static constexpr int64_t kInsert = 1;

  // WINDOW_REQUEST_RESULT's b as cmux gets it: the shim's low 32 bits (outcome | new tab << 8 | kind
  // << 16 | disposition << 24 | user gesture << 31) and, for an INSERT into `window` (the event's
  // request), the id minted for its tab << 32 (0: none). `source` is the event's browser_id.
  int64_t Result(int window, int source, int64_t b) {
    const uint64_t flags = static_cast<uint64_t>(b) & 0xffffffffu;
    const int32_t minted = (b & 0xff) == kInsert ? Mint(window, source) : 0;
    return static_cast<int64_t>(static_cast<uint64_t>(static_cast<uint32_t>(minted)) << 32 | flags);
  }

  // An INSERT into Chromium's window `window` that Chromium's browser `source` (0: none) requested:
  // the id its tab will have, for WINDOW_REQUEST_RESULT. 0 when `window` is 0 or the range is used up.
  int32_t Mint(int window, int source) {
    if (window == 0 || next_ == 0) return 0;
    const int32_t minted = next_;
    next_ = next_ < INT32_MAX ? next_ + 1 : 0;
    if (pending_.size() >= kMaxPending) pending_.pop_front();
    pending_.push_back(Pending{minted, window, source});
    return minted;
  }

  // A tab Chromium created itself (AFTER_CREATED with request 0), in Chromium's window `window` (0:
  // in none yet) and opened by Chromium's browser `opener` (0: none): the id minted for it, or 0.
  int32_t Take(int window, int opener) {
    for (auto it = pending_.begin(); it != pending_.end(); ++it) {
      const bool same = window != 0 ? it->window == window : opener != 0 && it->source == opener;
      if (!same) continue;
      const int32_t minted = it->minted;
      pending_.erase(it);
      return minted;
    }
    return 0;
  }

  size_t pending() const { return pending_.size(); }

 private:
  struct Pending {
    int32_t minted;
    int window;
    int source;
  };

  std::deque<Pending> pending_;
  int32_t next_ = mint::kFirstHostBrowserID;
};

}  // namespace cmux_host
