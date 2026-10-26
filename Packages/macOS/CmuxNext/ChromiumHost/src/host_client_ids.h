// The Chromium Host's map from the ids cmux minted to Chromium's
// (plans/cmux-next/chrome-parity/p01-process.md, task 019). cmux names every
// browser it creates (create_window, tab_add, tab_duplicate) and every
// DevTools call before the host has run it (chromium_host_mint.h), so no Swift
// path waits for the host to learn an id. The host translates every browser
// id an op carries to Chromium's, and every id an event carries back to the
// one cmux minted. Chrome's browser process mints the ids of the windows its
// app shim makes the same way, before the shim has made them
// (ui/views/cocoa/native_widget_mac_ns_window_host.mm, bridged_native_widget_id).
//
// The generated host cases (generated/host_dispatch.inc) reach this through
// HostContext (host_dispatch.h): ctx.Browser(id) is Browser, ctx.BindMinted is
// Bind or BindDevToolsCall, ctx.BindMintedOnEvent is BindOnEvent, and every
// shim event goes through ToClient before it is encoded. The shim runs
// OnAfterCreated inside tab_add and tab_duplicate, so HostContext holds the
// events an op causes until the op's case has bound its minted id.
//
// UI thread only, like every shim call: no lock (p01-process section 4, rule 1).
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <unordered_map>
#include <unordered_set>

#include "chromium_host_mint.h"

namespace cmux_host {

class ClientIds {
 public:
  // What a peer may hold at once; past it the wire is broken (bad_message).
  static constexpr size_t kMaxBrowsers = 65536;
  static constexpr size_t kMaxPendingCreates = 4096;
  static constexpr size_t kMaxDevToolsCalls = 65536;

  enum class Outcome {
    kBound,    // the minted id names the new browser or call
    // The shim refused the op: the id names nothing. cmux already holds a tab
    // under a tab_add or tab_duplicate id, so the host ends it as Chromium
    // ends a browser, with BEFORE_CLOSE(minted). A refused create_window
    // sends no AFTER_CREATED.
    kRefused,
    kBad,      // not an id of the minted range, one already in use, or past a bound
  };

  // One shim event's ids (cmux_shim_event_fn: kind, browser_id, request, a, b).
  struct Event {
    int kind = 0;
    int browser_id = 0;
    int request = 0;
    int64_t a = 0;
    int64_t b = 0;
  };

  ClientIds() = default;
  ClientIds(const ClientIds&) = delete;
  ClientIds& operator=(const ClientIds&) = delete;

  // Chromium's id for a browser argument of an op from cmux. A minted id with
  // no browser (refused, not created yet, closed) is 0, which names no
  // browser, so a late op never reaches another tab; an id below the minted
  // range is Chromium's own and passes as it is.
  int Browser(int32_t client_id) const;
  // The id cmux knows for a Chromium browser.
  int32_t ClientOf(int chromium_id) const;

  // tab_add and tab_duplicate: `result` is the shim's return, Chromium's id
  // of the new browser or 0.
  Outcome Bind(int32_t minted, int64_t result);
  // create_window: `started` is the shim's return (1: the browser comes in
  // the event of `event_kind` with `request`, which then gets the minted id).
  Outcome BindOnEvent(int32_t minted, int event_kind, int32_t request, int64_t started);
  // devtools_call on cmux's browser `client_browser`: `result` is the shim's
  // message id, which its DEVTOOLS_RESULT carries, or 0. On kRefused the
  // caller answers DEVTOOLS_RESULT with a = 0 and the minted id.
  Outcome BindDevToolsCall(int32_t client_browser, int32_t minted, int64_t result);

  // The event in cmux's ids: browser_id, the opener in AFTER_CREATED's b
  // (opener << 32 | flags), the DevTools browser in DEVTOOLS_OPENED and
  // DEVTOOLS_CLOSED's a, and DEVTOOLS_RESULT's message id. AFTER_CREATED of a
  // create_window binds its minted id; BEFORE_CLOSE forgets the browser after
  // its own translation.
  Event ToClient(const Event& chromium);

  size_t browsers() const { return chromium_of_.size(); }
  size_t pending_creates() const { return pending_.size(); }
  size_t devtools_calls() const { return devtools_.size(); }

 private:
  struct PendingKey {
    int kind;
    int32_t request;
    bool operator==(const PendingKey&) const = default;
  };
  struct PendingKeyHash {
    size_t operator()(const PendingKey& key) const {
      return std::hash<uint64_t>()((static_cast<uint64_t>(static_cast<uint32_t>(key.kind)) << 32) |
                                   static_cast<uint32_t>(key.request));
    }
  };

  static uint64_t DevToolsKey(int chromium_browser, int64_t message_id);
  Outcome Link(int32_t minted, int64_t chromium);
  void Forget(int chromium_id);

  std::unordered_map<int32_t, int> chromium_of_;
  std::unordered_map<int, int32_t> client_of_;
  std::unordered_map<PendingKey, int32_t, PendingKeyHash> pending_;
  std::unordered_set<int32_t> awaiting_;  // the minted ids in pending_
  // (Chromium browser << 32 | the shim's message id) -> the minted message id.
  std::unordered_map<uint64_t, int32_t> devtools_;
};

}  // namespace cmux_host
