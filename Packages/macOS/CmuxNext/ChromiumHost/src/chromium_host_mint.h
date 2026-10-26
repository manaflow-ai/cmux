// The id ranges cmux mints in host mode (plans/cmux-next/chrome-parity/p01-process.md, tasks 014
// and 019), shared by the remote shim, which mints them (../client/remote_shim.mm, MintID), and
// the host, which maps them to Chromium's (host_client_ids.h). Header-only, no CEF.
//
// Browser ids (create_window, tab_add, tab_duplicate) start at kFirstBrowserID, above every id
// Chromium gives a browser in one host's life, so an id below it is always Chromium's own (a tab
// Chromium opened: a popup, target=_blank, chrome.tabs.create, a DevTools browser). DevTools
// message ids (devtools_call) are in [kFirstDevToolsID, kEndDevToolsID): below 2^30, the
// header's shim-internal range, and above the host shim's own counter.
#pragma once

#include <cstdint>

namespace cmux_host::mint {

inline constexpr int32_t kFirstBrowserID = 1 << 20;
inline constexpr int32_t kFirstDevToolsID = 1 << 29;
inline constexpr int32_t kEndDevToolsID = 1 << 30;

inline constexpr bool IsMintedBrowser(int64_t id) {
  return id >= kFirstBrowserID && id <= INT32_MAX;
}

inline constexpr bool IsMintedDevTools(int64_t id) {
  return id >= kFirstDevToolsID && id < kEndDevToolsID;
}

}  // namespace cmux_host::mint
