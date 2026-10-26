// The id ranges cmux mints in host mode (plans/cmux-next/chrome-parity/p01-process.md, tasks 014
// and 019), shared by the remote shim, which mints them (../client/remote_shim.mm, MintID), and
// the host, which maps them to Chromium's (host_client_ids.h). Header-only, no CEF.
//
// Browser ids (create_window, tab_add, tab_duplicate) are in [kFirstBrowserID, kFirstHostBrowserID),
// above every id Chromium gives a browser in one host's life, so an id below it is always Chromium's
// own. A tab Chromium opens for a window request the host decided with cmux's pushed policy (a popup,
// target=_blank, chrome.windows.create; task 031) gets an id the host mints, in [kFirstHostBrowserID,
// INT32_MAX]: CMUX_SHIM_WINDOW_REQUEST_RESULT carries it before the tab exists, and the tab's
// AFTER_CREATED binds it (host_window_request_ids.h), so cmux adopts the tab under it. Chrome's
// browser process mints a new WebContents' ids as the navigation places it, before the tab strip
// shows it (chrome/browser/ui/browser_navigator.cc). Any other tab Chromium opens itself (a DevTools
// browser, a tab whose request the host never saw) keeps Chromium's id, the same number on both
// sides; the host ends if Chromium's counter ever reaches the minted range. DevTools message ids
// (devtools_call) are in [kFirstDevToolsID, kEndDevToolsID): below 2^30, the header's shim-internal
// range, and above the host shim's own counter.
#pragma once

#include <cstdint>

namespace cmux_host::mint {

inline constexpr int32_t kFirstBrowserID = 1 << 20;
inline constexpr int32_t kFirstHostBrowserID = 1 << 30;
inline constexpr int32_t kFirstDevToolsID = 1 << 29;
inline constexpr int32_t kEndDevToolsID = 1 << 30;

// CMUX_SHIM_CREATE_FAILED (plans/cmux-next/chromium-host-ops.json, optional_events): the host
// refused a browser cmux minted. browser_id = the minted id, request = create_window's request
// (0 for tab_add and tab_duplicate). Host mode only: in process the shim's 0 return says it.
inline constexpr int kEventCreateFailed = 51;

// The name a host lists in its HELLO's exports once it maps cmux's ids (ClientIds behind its
// HostContext). cmux creates a browser in the key's turn only for such a host (CEFAttachedHost).
inline constexpr char kClientIdsHelloName[] = "cmux_host_client_ids";

// Minted by cmux or by the host: a browser of the client id space.
inline constexpr bool IsMintedBrowser(int64_t id) {
  return id >= kFirstBrowserID && id <= INT32_MAX;
}

inline constexpr bool IsHostMintedBrowser(int64_t id) {
  return id >= kFirstHostBrowserID && id <= INT32_MAX;
}

inline constexpr bool IsMintedDevTools(int64_t id) {
  return id >= kFirstDevToolsID && id < kEndDevToolsID;
}

}  // namespace cmux_host::mint
