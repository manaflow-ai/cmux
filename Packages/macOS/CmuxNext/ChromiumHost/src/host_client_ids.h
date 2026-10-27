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
// HostContext (host_dispatch.h) owns one and wires it to the generated cases
// (generated/host_dispatch.inc):
//   ctx.Browser(id)                        Browser(id)
//   DispatchOp(...)                        between BeginCall() and EndCall()
//   ctx.BindMinted(op, minted, result, browser)
//                                          Bind (tab_add, tab_duplicate) or
//                                          BindDevToolsCall (devtools_call)
//   ctx.BindMintedOnEvent(...)             BindOnEvent (create_window)
//   the shim's event_fn                    FromShim(event); false ends the host
// and sends what `emit` gets as EVENT frames.
//
// UI thread only, like every shim call: no lock (p01-process section 4, rule 1).
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

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
    // The shim refused the op: the id names nothing, and cmux hears it as in
    // process from the 0 return. A browser: CREATE_FAILED(minted, request)
    // (mint::kEventCreateFailed); a DevTools call: DEVTOOLS_RESULT(the
    // caller's browser, minted, a = 0).
    kRefused,
    kBad,      // not an id of the minted range, one already in use, or past a bound
  };

  // One shim event (cmux_shim_event_fn's arguments).
  struct Event {
    int kind = 0;
    int browser_id = 0;
    int request = 0;
    int64_t a = 0;
    int64_t b = 0;
    std::string s1;
    std::string s2;
  };
  // Takes each event in cmux's ids, in the order Chromium emitted them.
  using Emit = std::function<void(const Event&)>;

  explicit ClientIds(Emit emit) : emit_(std::move(emit)) {}
  ClientIds(const ClientIds&) = delete;
  ClientIds& operator=(const ClientIds&) = delete;

  // Chromium's id for a browser argument of an op from cmux. A minted id with
  // no browser (refused, not created yet, closed) is 0, which names no
  // browser, so a late op never reaches another tab; an id below the minted
  // range is Chromium's own and passes as it is.
  int Browser(int32_t client_id) const;
  // The id cmux knows for a Chromium browser.
  int32_t ClientOf(int chromium_id) const;

  // Around one op's shim call. The shim runs OnAfterCreated inside tab_add and
  // tab_duplicate, before the op's case can bind its minted id: the events a
  // call emits wait until EndCall, which sends them in cmux's ids, then what
  // a refusal adds. Calls do not nest (one op at a time on the UI thread).
  void BeginCall();
  void EndCall();

  // tab_add and tab_duplicate: `result` is the shim's return, Chromium's id
  // of the new browser or 0.
  Outcome Bind(int32_t minted, int64_t result);
  // create_window: `started` is the shim's return (1: the browser comes in
  // the event of `event_kind` with `request`, which then gets the minted id).
  Outcome BindOnEvent(int32_t minted, int event_kind, int32_t request, int64_t started);
  // devtools_call on cmux's browser `client_browser` (the op's argument as
  // cmux sent it): `result` is the shim's message id, which its
  // DEVTOOLS_RESULT carries, or 0.
  Outcome BindDevToolsCall(int32_t client_browser, int32_t minted, int64_t result);

  // A shim event. Sent in cmux's ids: browser_id, the opener in
  // AFTER_CREATED's b (opener << 32 | flags), the DevTools browser in
  // DEVTOOLS_OPENED and DEVTOOLS_CLOSED's a, and DEVTOOLS_RESULT's message id.
  // AFTER_CREATED of a create_window binds its minted id; BEFORE_CLOSE
  // forgets the browser after its own translation. False when Chromium named
  // a new browser by an id of the minted range: the id spaces met, and the
  // host must end (a new host starts Chromium's counter again).
  bool FromShim(const Event& chromium);

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
  // An event held during a call: Chromium's (translated when sent) or one
  // this map made, already in cmux's ids.
  struct Held {
    Event event;
    bool in_client_ids;
  };

  static uint64_t DevToolsKey(int chromium_browser, int64_t message_id);
  Event ToClient(const Event& chromium);
  void Send(Event event);
  Outcome Link(int32_t minted, int64_t chromium);
  void Forget(int chromium_id);

  Emit emit_;
  bool in_call_ = false;
  std::vector<Held> held_;
  std::unordered_map<int32_t, int> chromium_of_;
  std::unordered_map<int, int32_t> client_of_;
  std::unordered_map<PendingKey, int32_t, PendingKeyHash> pending_;
  std::unordered_set<int32_t> awaiting_;  // the minted ids in pending_
  // (Chromium browser << 32 | the shim's message id) -> the minted message id.
  std::unordered_map<uint64_t, int32_t> devtools_;
};

}  // namespace cmux_host
