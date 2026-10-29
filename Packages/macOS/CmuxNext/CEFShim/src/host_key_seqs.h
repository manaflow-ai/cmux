// The Command and Control key-downs the Chromium Host sent to each page, by
// the input seq of the frame that carried each (Header::seq, task 092), until
// the page leaves one unhandled (no CEF needed:
// scripts/cmux-next/tests/shim-host-key-seqs.test.sh).
//
// In host mode cmux's KeyRouter decides first, in CmuxApplication.sendEvent;
// the host never asks cmux before the page (key_fn is NULL). A chord the page
// leaves unhandled goes back as KEY_UNHANDLED with its seq, and cmux runs the
// action it held or re-dispatches the key to its menus, as Chrome re-dispatches
// a key its renderer left unhandled (ui/base/cocoa/command_dispatcher.mm,
// -redispatchKeyEvent:; out of process, RedispatchKeyEvent in
// components/remote_cocoa/common/native_widget_ns_window.mojom).
//
// A report names its key exactly, as Chrome's ack carries back the queued
// NativeWebKeyboardEvent itself (content/browser/renderer_host/input/
// input_router_impl.cc, OnKeyboardEventAck): CefBrowserHost::SendKeyEvent
// wraps the key in an os_event, calls OnPreKeyEvent with it on the way in
// and OnKeyEvent with the same os_event if the page leaves it unhandled.
// SendHostKeyEvent expects the seq (Expect), OnPreKeyEvent binds it to that
// os_event (Bind), and OnKeyEvent takes it back by the os_event (Take). A key
// the page handled is never reported; it stays until a later key reuses its
// os_event's address (the event was freed, so its key was acked) or the
// limit drops it.
#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <map>

namespace cmux_shim {

class HostKeySeqs {
 public:
  // Keys held per browser at most; the oldest are dropped first.
  static constexpr size_t kLimit = 64;
  // KEY_UNHANDLED's b for a chord report: bit 1, and bit 0 with Shift.
  static constexpr int64_t kShiftBit = 1;
  static constexpr int64_t kChordBit = 2;
  // EVENTFLAG_SHIFT_DOWN, CONTROL_DOWN and COMMAND_DOWN (cef_types.h;
  // shim_client.mm checks them).
  static constexpr uint32_t kShiftDown = 1u << 1;
  static constexpr uint32_t kControlDown = 1u << 2;
  static constexpr uint32_t kCommandDown = 1u << 7;

  // Whether a key-down with these CEF event flags is a chord cmux may want
  // back: Command or Control held.
  static bool IsChord(uint32_t modifiers) { return (modifiers & (kCommandDown | kControlDown)) != 0; }

  // KEY_UNHANDLED's b for an unhandled chord with these flags.
  static int64_t ChordBits(uint32_t modifiers) { return kChordBit | ((modifiers & kShiftDown) ? kShiftBit : 0); }

  // Whether OnKeyEvent reports an unhandled key-down as a chord: the host has
  // no unhandled-key handler (the Chromium Host), the key came with a seq and
  // is a chord. In process the handler answers instead.
  static bool ReportsChord(bool has_unhandled_key_handler, uint32_t seq, uint32_t modifiers) {
    return !has_unhandled_key_handler && seq != 0 && IsChord(modifiers);
  }

  // The host is about to send key-down `seq` (never 0) to `browser_id`.
  void Expect(int browser_id, uint32_t seq) { expected_ = Expected{browser_id, seq}; }

  // OnPreKeyEvent for `browser_id` with the event Chromium queued: the key
  // expected for it now has that event. Without one (in process, or another
  // browser), nothing changes.
  void Bind(int browser_id, const void* queued_event) {
    if (expected_.seq == 0 || expected_.browser_id != browser_id || queued_event == nullptr) return;
    const uint32_t seq = expected_.seq;
    expected_ = Expected{};
    std::deque<Entry>& keys = keys_[browser_id];
    Erase(keys, queued_event);
    keys.push_back(Entry{queued_event, seq});
    while (keys.size() > kLimit) keys.pop_front();
  }

  // SendKeyEvent returned: a key Chromium did not queue (no page widget)
  // binds to nothing.
  void EndSend() { expected_ = Expected{}; }

  // The seq of the key-down whose event is `queued_event`, which the page left
  // unhandled; it is released. 0 when none is held: a key that did not come
  // over the wire.
  uint32_t Take(int browser_id, const void* queued_event) {
    auto found = keys_.find(browser_id);
    if (found == keys_.end() || queued_event == nullptr) return 0;
    const uint32_t seq = Erase(found->second, queued_event);
    if (found->second.empty()) keys_.erase(found);
    return seq;
  }

  // The browser closed.
  void Forget(int browser_id) {
    keys_.erase(browser_id);
    if (expected_.browser_id == browser_id) expected_ = Expected{};
  }

  size_t Held(int browser_id) const {
    auto found = keys_.find(browser_id);
    return found == keys_.end() ? 0 : found->second.size();
  }

 private:
  struct Entry {
    const void* event;
    uint32_t seq;
  };
  struct Expected {
    int browser_id = 0;
    uint32_t seq = 0;
  };

  // Removes the entry of `event`; its seq, or 0.
  static uint32_t Erase(std::deque<Entry>& keys, const void* event) {
    for (auto it = keys.begin(); it != keys.end(); ++it) {
      if (it->event != event) continue;
      const uint32_t seq = it->seq;
      keys.erase(it);
      return seq;
    }
    return 0;
  }

  std::map<int, std::deque<Entry>> keys_;
  Expected expected_;
};

}  // namespace cmux_shim
