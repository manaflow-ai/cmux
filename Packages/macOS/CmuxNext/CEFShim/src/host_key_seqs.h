// The key-downs the Chromium Host sent to each page, by the seq cmux gave
// each key frame (p01-process-030), until the page handled the key or left
// it unhandled (no CEF needed; scripts/cmux-next/tests/shim-host-key-seqs.test.sh).
//
// In host mode cmux's KeyRouter decides first, in CmuxApplication.sendEvent;
// the host never asks cmux before the page (key_fn is NULL). A key the page
// leaves unhandled goes back as KEY_UNHANDLED with its seq, and cmux
// re-dispatches it to its menus, as Chrome re-dispatches a key its renderer
// left unhandled (ui/base/cocoa/command_dispatcher.mm, -redispatchKeyEvent:;
// out of process, RedispatchKeyEvent in
// components/remote_cocoa/common/native_widget_ns_window.mojom).
//
// A widget acks its key events in the order it got them
// (content/browser/renderer_host/render_widget_host_impl.cc, the key event
// queue), and only an unhandled key reaches CefKeyboardHandler::OnKeyEvent.
// So a report releases its key and every older one: those the page handled.
#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <map>

namespace cmux_shim {

class HostKeySeqs {
 public:
  // Keys held per browser at most; a page that never reports drops the oldest.
  static constexpr size_t kLimit = 64;
  // EVENTFLAG_SHIFT_DOWN, CONTROL_DOWN, ALT_DOWN and COMMAND_DOWN
  // (cef_types.h; shim_client.mm checks them): the flags the person pressed.
  // Chromium may add others on the way back (caps lock, key pad, left or
  // right), which do not name a key.
  static constexpr uint32_t kMatched = (1u << 1) | (1u << 2) | (1u << 3) | (1u << 7);

  // The host sent key-down `seq` (never 0) to `browser_id`. `native_key_code`
  // is the macOS key code, `modifiers` the CEF event flags it sent.
  void Note(int browser_id, uint32_t seq, int native_key_code, uint32_t modifiers) {
    if (seq == 0) return;
    std::deque<Entry>& keys = keys_[browser_id];
    keys.push_back(Entry{seq, native_key_code, modifiers & kMatched});
    while (keys.size() > kLimit) keys.pop_front();
  }

  // The seq of the oldest held key-down of `browser_id` with this key code
  // and modifiers, which the page left unhandled; it and every older one are
  // released. 0 when none is held: a key that did not come over the wire
  // (in process, cmux's own key callbacks answer).
  uint32_t Take(int browser_id, int native_key_code, uint32_t modifiers) {
    auto found = keys_.find(browser_id);
    if (found == keys_.end()) return 0;
    std::deque<Entry>& keys = found->second;
    const uint32_t matched = modifiers & kMatched;
    for (size_t i = 0; i < keys.size(); ++i) {
      if (keys[i].native_key_code != native_key_code || keys[i].modifiers != matched) continue;
      const uint32_t seq = keys[i].seq;
      keys.erase(keys.begin(), keys.begin() + static_cast<std::ptrdiff_t>(i) + 1);
      if (keys.empty()) keys_.erase(found);
      return seq;
    }
    return 0;
  }

  // The browser closed.
  void Forget(int browser_id) { keys_.erase(browser_id); }

  size_t Held(int browser_id) const {
    auto found = keys_.find(browser_id);
    return found == keys_.end() ? 0 : found->second.size();
  }

 private:
  struct Entry {
    uint32_t seq;
    int native_key_code;
    uint32_t modifiers;
  };
  std::map<int, std::deque<Entry>> keys_;
};

}  // namespace cmux_shim
