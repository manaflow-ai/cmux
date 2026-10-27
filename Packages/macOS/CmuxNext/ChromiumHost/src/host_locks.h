// Pointer lock and keyboard lock in host mode (plans/cmux-next/chrome-parity/
// p01-process.md, task 229). The fork's lock delegate (task 227,
// cmux_shim_set_lock_handler) runs in the Chromium Host; cmux decides, hides
// and frees its own cursor and keeps reserved keys for the page, as Chrome's
// app shim does for RenderWidgetHostViewMac (SetCursorLocked, LockKeyboard in
// content/common/render_widget_host_ns_view.mojom). A function pointer cannot
// cross the process, so only the handler's on/off crosses the wire:
//
//   cmux -> host  kOpSetLockHandler (the export's generated op id, sent by
//                 hand: its class is local)  i32 installed (0 or 1). The host
//                 installs its own handler in the fork while it is 1.
//   host -> cmux  kOpEvent CMUX_SHIM_LOCK: request = cmux_shim_lock_event_t,
//                 a = its detail. The remote shim calls cmux's fn with them
//                 (LockClient), never cmux's event fn.
//
// The answers and exits are generated posts (cmux_shim_browser_*_lock_*), and
// the locked movement is cmux_shim_browser_send_locked_mouse_move on the
// input channel.
//
// A host whose fork has the lock delegate lists kLocksHelloName in its HELLO;
// cmux's remote shim refuses the op to a host without it, as it refuses an
// optional export, and cmux_shim_set_lock_handler answers 0 there as the
// in-process shim does on a fork without the call.
//
// Plain C++, no CEF: the tests build it on Linux
// (scripts/cmux-next/tests/chromium-host-dispatch.test.sh,
// remote-shim-abi.test.sh).
#pragma once

#include <cstdint>
#include <optional>
#include <set>
#include <vector>

#include "chromium_host_tlv.h"
#include "cmux_cef_shim.h"

namespace cmux_host {

// The name a host lists in its HELLO's exports when its fork has the lock
// delegate (cmux_shim::fork_api().set_lock_handler).
inline constexpr char kLocksHelloName[] = "cmux_host_locks";

// cmux_shim_set_lock_handler's signature.
using LockFn = void (*)(void* context, int event, int browser_id, int detail);
using SetLockHandlerFn = int (*)(LockFn fn, void* context);

// Writes kOpSetLockHandler's fields (the remote shim's side).
inline void WriteLockHandler(bool installed, control::TlvWriter* w) {
  w->I32(installed ? 1 : 0);
}

// The op's installed flag; nullopt for a malformed op.
inline std::optional<bool> DecodeLockHandler(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  const int32_t installed = r.I32();
  if (!r.ok() || !r.AtEnd() || (installed != 0 && installed != 1)) return std::nullopt;
  return installed == 1;
}

// The remote shim's side of the lock handler: cmux's fn, and the browsers
// whose lock the host's fork may hold, so a host that ends (its pages end
// with it) frees cmux's cursor and keys, as Chrome's RenderWidgetHostViewMac
// unlocks when its renderer goes (LostPointerLock). Main thread only.
class LockClient {
 public:
  // cmux's fn, NULL for none. Removing it forgets every lock: the host's
  // fork ends them itself.
  void Set(LockFn fn, void* context) {
    fn_ = fn;
    context_ = context;
    if (!fn) {
      pointer_.clear();
      keyboard_.clear();
    }
  }

  bool installed() const { return fn_ != nullptr; }

  // A CMUX_SHIM_LOCK push. A request counts as held until its unlock: cmux
  // may have locked its cursor before it answered. False with no fn or an
  // event this side does not know (nothing is called).
  bool Deliver(int event, int browser_id, int detail) {
    if (!fn_) return false;
    switch (event) {
      case CMUX_SHIM_POINTER_LOCK_REQUESTED:
        pointer_.insert(browser_id);
        break;
      case CMUX_SHIM_POINTER_UNLOCKED:
        pointer_.erase(browser_id);
        break;
      case CMUX_SHIM_KEYBOARD_LOCK_REQUESTED:
        keyboard_.insert(browser_id);
        break;
      case CMUX_SHIM_KEYBOARD_UNLOCKED:
        keyboard_.erase(browser_id);
        break;
      default:
        return false;
    }
    fn_(context_, event, browser_id, detail);
    return true;
  }

  // The host is gone: fn hears POINTER_UNLOCKED, then KEYBOARD_UNLOCKED, for
  // each browser that may hold one. Swapped out first, so a lock fn calls
  // back into a clean state.
  void HostGone() {
    std::set<int> pointer;
    std::set<int> keyboard;
    pointer.swap(pointer_);
    keyboard.swap(keyboard_);
    if (!fn_) return;
    for (int browser : pointer) fn_(context_, CMUX_SHIM_POINTER_UNLOCKED, browser, 0);
    for (int browser : keyboard) fn_(context_, CMUX_SHIM_KEYBOARD_UNLOCKED, browser, 0);
  }

  size_t held() const { return pointer_.size() + keyboard_.size(); }

 private:
  LockFn fn_ = nullptr;
  void* context_ = nullptr;
  std::set<int> pointer_;   // browsers that asked for, or hold, a pointer lock
  std::set<int> keyboard_;  // the same for a keyboard lock
};

}  // namespace cmux_host
