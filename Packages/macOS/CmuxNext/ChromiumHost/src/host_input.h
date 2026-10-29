// The Chromium Host's input dispatch (plans/cmux-next/chrome-parity/p01-process.md 3.1).
//
// The input ring's reader (chromium_host_input_ring.h, HostInput) hands each batch of frames
// to the UI thread through the host's InputTasks (host_user_input.h):
// Chromium's user-input queue (BrowserTaskType::kUserInput in
// content/public/browser/browser_task_traits.h), or CefPostTask(TID_UI) on a fork without it;
// there the frames go into the host's one ordered stream (OrderedInput, task 092), which
// dispatches each once the control message it follows is applied and input is open;
// browser_host_main.mm's DispatchInput sends it to its page and its move or wheel tick is
// acked (kOpInputAck) then, never when the renderer handled it. cmux sends at most one move and one wheel tick per page before their ack and
// coalesces the rest (ChromiumHostInputPacer in cmux), so the host never coalesces input.
//
// AckBatch and OrderedInput need no CEF (the ring test builds them on any machine);
// DispatchInputFrame is host_input.mm.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <utility>
#include <vector>

#include "chromium_host_control.h"
#include "chromium_host_input_ring.h"
#include "chromium_host_tlv.h"
#include "chromium_host_wire.h"

namespace cmux_host {

// Sends `frame` (kKey, kMouse or kEdit, chromium_host_wire.h) to the browser Chromium names
// `chromium_browser_id`; nothing for a browser that is gone or another kind (wheels go through
// browser_host_main.mm's SendWheel). UI thread.
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

// The host's ring input on the UI thread: each ring frame goes into the ordered stream (task
// 092), which holds it until the control message it names is applied and until input opens
// (after initialize); a frame is sent to its page and acked only when the stream dispatches
// it. So a key or click never passes an earlier focus, IME, geometry or embedder-active op,
// a frame that came before initialize waits for the browsers instead of being lost, and an
// ack always means "dispatched". UI thread only, like the stream.
class OrderedInput {
 public:
  // Sends one dispatched frame to its page (DispatchInput in browser_host_main.mm).
  using Dispatch = std::function<void(const Header&)>;
  // Sends the acks of the frames dispatched by one call (the control channel).
  using SendAcks = std::function<void(control::Message)>;
  // The stream is malformed (`what` says why): the host ends.
  using Malformed = std::function<void(const char* what)>;

  OrderedInput(control::OrderedStream& ordered, Dispatch dispatch, SendAcks send, Malformed malformed)
      : ordered_(ordered), dispatch_(std::move(dispatch)), send_(std::move(send)), malformed_(std::move(malformed)) {
    ordered_.AttachInput([this](const Header& frame) {
      dispatch_(frame);
      acks_.Add(frame);
    });
  }
  OrderedInput(const OrderedInput&) = delete;
  OrderedInput& operator=(const OrderedInput&) = delete;

  // A ring batch from `from` (input_ring::HostInput's Deliver): how many frames the stream
  // took. It stops at the first frame a full stream refuses; that one and the rest stay with
  // the reader, whose gate keeps later frames in the ring, until Retry after the next control
  // message or OpenInput. After a malformed frame every frame counts as taken: the host ends.
  size_t Take(const std::vector<Header>& frames, size_t from) {
    size_t taken = 0;
    for (size_t index = from; index < frames.size(); ++index) {
      const control::OrderedStream::Result result = ordered_.AddInput(frames[index]);
      if (result == control::OrderedStream::Result::kFull) break;
      if (result == control::OrderedStream::Result::kMalformed) {
        Flush();
        malformed_(ordered_.what());
        return frames.size() - from;
      }
      ++taken;
    }
    Flush();
    return taken;
  }

  // After every other call into the stream (AddControl, OpenInput): what it dispatched is acked.
  void After(control::OrderedStream::Result result) {
    Flush();
    if (result == control::OrderedStream::Result::kMalformed) malformed_(ordered_.what());
  }

 private:
  void Flush() {
    if (!acks_.empty()) send_(acks_.Take());
  }

  control::OrderedStream& ordered_;
  const Dispatch dispatch_;
  const SendAcks send_;
  const Malformed malformed_;
  AckBatch acks_;
};

}  // namespace cmux_host
