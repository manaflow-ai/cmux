// The Chromium Host's input dispatch (plans/cmux-next/chrome-parity/p01-process.md 3.1, task
// p01-process-042).
//
// The input ring's reader (chromium_host_input_ring.h, HostInput) hands each batch of frames
// to the UI thread on Chromium's user-input queue (cmux_shim_post_user_input_task,
// BrowserTaskType::kUserInput in content/public/browser/browser_task_traits.h); there
// DispatchInputFrame sends each frame to its page and the batch's moves and wheel ticks are
// acked (kOpInputAck) once they are dispatched, never when the renderer handled them. cmux sends
// at most one move and one wheel tick per page before their ack and coalesces the rest
// (ChromiumHostInputPacer in cmux), so the host never holds or coalesces input itself.
//
// AckBatch needs no CEF (the ring test builds it on any machine); DispatchInputFrame is
// host_input.mm.
#pragma once

#include <cstddef>
#include <cstdint>

#include "chromium_host_control.h"
#include "chromium_host_input_ring.h"
#include "chromium_host_tlv.h"
#include "chromium_host_wire.h"

namespace cmux_host {

// Sends `frame` (kKey, kMouse or kWheel, chromium_host_wire.h) to the browser Chromium names
// `chromium_browser_id`; nothing for a browser that is gone or a kind the ring does not carry.
// UI thread.
void DispatchInputFrame(int chromium_browser_id, const Header& frame);

// The acks of one dispatched batch: one record per pointer move and wheel tick, the frames
// cmux paces. UI thread.
class AckBatch {
 public:
  // A frame cmux waits for the ack of: a pointer move (kMouse phase 0) or a wheel tick.
  static bool IsPaced(const Header& frame) { return IsPointerMove(frame) || frame.kind == kWheel; }

  void Add(const Header& frame) {
    if (!IsPaced(frame)) return;
    writer_.I32(input_ring::BrowserOf(frame));
    writer_.I32(static_cast<int32_t>(frame.kind));
    writer_.U32(frame.seq);
    ++count_;
  }

  bool empty() const { return count_ == 0; }
  size_t count() const { return count_; }

  // The kOpInputAck message of every frame added since the last Take; empties the batch.
  control::Message Take() {
    control::Message message;
    message.op = control::kOpInputAck;
    message.fields = writer_.Take();
    writer_ = control::TlvWriter();
    count_ = 0;
    return message;
  }

 private:
  control::TlvWriter writer_;
  size_t count_ = 0;
};

}  // namespace cmux_host
