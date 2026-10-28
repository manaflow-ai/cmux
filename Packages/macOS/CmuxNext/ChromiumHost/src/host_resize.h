// A hosted page's resize and its Core Animation fence, from cmux to the
// Chromium Host (plans/cmux-next/chrome-parity/p01-process.md 3.1 and 3.3).
//
// cmux resizes a page view in one main-thread turn and holds that turn's
// Core Animation commit on a fence port of its window's context
// (-[CAContext createFencePort], -setFencePort:) until the page's commit at
// the new size joins it, so the pane and the page show their new size in one
// WindowServer update. WebKit fences a web view's resize the same way: the UI
// process makes the fence (TiledCoreAnimationDrawingAreaProxy::createFence,
// Source/WebKit/UIProcess/mac/TiledCoreAnimationDrawingAreaProxy.mm) and the
// web process's commit at the new size joins it
// (TiledCoreAnimationDrawingArea::updateGeometry). Here the host gives the
// fence to the fork (cmux_shim_browser_set_resize_fence, fork API 32) right
// before the page window's frame change, in the same turn, as that call asks.
//
// Two channels, one join by seq:
//   Mach  the fence right, a port descriptor (MACH_MSG_TYPE_COPY_SEND) in a
//         FenceMessage to the receive right the host checked in under
//         --resize-fence=<name> (bootstrap_check_in, as the input doorbell:
//         chromium_host_input_ring.h). A Unix socket carries no Mach right,
//         and XPC carries one only through private calls; Mojo's ChannelMac
//         sends Mach rights the same way (mojo/core/channel_mac.cc).
//   control kOpPageResize, an ordered op (task 092: geometry is on the one
//         ordered stream, as OnBoundsInWindowChanged is on Chrome's
//         RenderWidgetHostNSViewHost pipe):
//           i64 page view token, i32 browser (cmux's id of the shown tab),
//           i32 width, i32 height (points), i64 fence seq (0: no fence),
//           i32 deadline (display frames)
//         A fenced op has a token and is answered with kOpReply, i32 1 when
//         the fork took the fence, 0 when not (no fence in the queue, a fork
//         without the call, a hidden page).
// cmux sends the Mach message first, so when the host reads the op its fence
// is in the port's queue already, and the host takes it without waiting
// (MACH_RCV_TIMEOUT 0). The deadline the host passes is at most
// kMaxFenceDeadlineFrames, counted by the fork from its join. cmux bounds the
// hold from its own commit: a host that joins after that commit has the
// window's fences ended by cmux one frame after the commit
// (ChromiumHostResizeFence.swift), and the commit shows the page's last frame
// on its background.
//
// Plain C++ apart from the Mach parts (__APPLE__), so the tests build it on
// Linux (scripts/cmux-next/tests/chromium-host-dispatch.test.sh).
#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "chromium_host_tlv.h"

#if defined(__APPLE__)
#include <mach/mach.h>
#endif

namespace cmux_host {

// Next to kOpGeometryStats (host_dispatch.h): not in the generated op table.
inline constexpr uint16_t kOpPageResize = 0x800a;
// The host's switch naming its inbox: --resize-fence=<bootstrap name>
// (ChromiumHostResizeFenceChannel.argument in cmux).
inline constexpr char kResizeFenceSwitch[] = "resize-fence";
// The longest a page may hold cmux's commit: one display frame.
inline constexpr uint32_t kMaxFenceDeadlineFrames = 1;
// Fence messages the host's port queues; a full queue makes cmux's send time
// out at once, and that resize goes unfenced.
inline constexpr uint32_t kFenceQueueLimit = 64;
// Fences the host keeps for ops still to come; older ones are released first.
inline constexpr size_t kMaxPendingFences = 64;
// FenceMessage's msgh_id: 'cmrf'.
inline constexpr int32_t kFenceMessageID = 0x636d7266;

// kOpPageResize's fields.
struct PageResize {
  uint64_t view = 0;
  int32_t browser = 0;
  int32_t width = 0;
  int32_t height = 0;
  uint64_t fence_seq = 0;
  uint32_t deadline_frames = 0;
};

// The op's fields; nullopt for a malformed op (wrong types, extra fields, a
// view token 0, a size under 1 point or over 32,767, a negative deadline).
inline std::optional<PageResize> DecodePageResize(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  PageResize resize;
  resize.view = r.View();
  resize.browser = r.I32();
  resize.width = r.I32();
  resize.height = r.I32();
  resize.fence_seq = static_cast<uint64_t>(r.I64());
  const int32_t deadline = r.I32();
  constexpr int32_t kMaxSide = 32767;
  if (!r.ok() || !r.AtEnd() || resize.view == 0 || resize.width < 1 || resize.height < 1 ||
      resize.width > kMaxSide || resize.height > kMaxSide || deadline < 0) {
    return std::nullopt;
  }
  resize.deadline_frames = static_cast<uint32_t>(deadline);
  return resize;
}

// Writes kOpPageResize's fields for `resize` (the remote shim's side).
inline void WritePageResize(const PageResize& resize, control::TlvWriter* w) {
  w->ViewToken(resize.view);
  w->I32(resize.browser);
  w->I32(resize.width);
  w->I32(resize.height);
  w->I64(static_cast<int64_t>(resize.fence_seq));
  w->I32(static_cast<int32_t>(resize.deadline_frames));
}

// A fence right the host received, and the seq cmux gave it.
struct Fence {
  uint64_t seq = 0;
  uint32_t right = 0;  // a send right in the host's space
};

// Where fence rights arrive (host_resize.mm: the Mach port; the tests: a
// fake). Main thread only.
class FenceInbox {
 public:
  virtual ~FenceInbox() = default;
  // Every fence waiting now, oldest first, without waiting.
  virtual std::vector<Fence> Drain() = 0;
  // Drops a right Drain returned.
  virtual void Release(uint32_t right) = 0;
};

// The fences received for ops still to come, oldest first. cmux's seqs only
// grow, so a fence older than the op being applied belongs to an op that
// will not come (a send that failed, a host restart) and is released then,
// as is any fence past kMaxPendingFences. Main thread only.
class FenceBook {
 public:
  explicit FenceBook(FenceInbox* inbox) : inbox_(inbox) {}
  FenceBook(const FenceBook&) = delete;
  FenceBook& operator=(const FenceBook&) = delete;
  ~FenceBook() {
    for (const Fence& fence : pending_) inbox_->Release(fence.right);
  }

  // The right for `seq`, which the caller now owns; 0 when none came.
  uint32_t Take(uint64_t seq) {
    if (inbox_ == nullptr || seq == 0) return 0;
    for (const Fence& fence : inbox_->Drain()) {
      pending_.push_back(fence);
      if (pending_.size() > kMaxPendingFences) Drop();
    }
    while (!pending_.empty() && pending_.front().seq < seq) Drop();
    if (pending_.empty() || pending_.front().seq != seq) return 0;
    const uint32_t right = pending_.front().right;
    pending_.pop_front();
    return right;
  }

  size_t pending() const { return pending_.size(); }
  uint64_t dropped() const { return dropped_; }

 private:
  void Drop() {
    inbox_->Release(pending_.front().right);
    pending_.pop_front();
    ++dropped_;
  }

  FenceInbox* inbox_;
  std::deque<Fence> pending_;
  uint64_t dropped_ = 0;
};

// Applies kOpPageResize: the fence first (`join`, the fork's call, with the
// Chromium id of the op's browser), then the frame change (`resize`). The
// host's own right is released once the fork took its own. Main thread only.
class PageResizes {
 public:
  // cmux_shim_browser_set_resize_fence: 1 when the fork took a right of its own.
  using Join = std::function<int(int chromium_browser, uint32_t right, uint32_t deadline_frames)>;

  struct Stats {
    uint64_t resizes = 0;  // ops applied
    uint64_t fenced = 0;   // ops with a fence seq
    uint64_t joined = 0;   // fences the fork took
    uint64_t missing = 0;  // fenced ops whose right was not in the queue
  };

  // `inbox` nullptr: the host took no --resize-fence; every fenced op is answered 0.
  PageResizes(FenceInbox* inbox, Join join) : inbox_(inbox), book_(inbox), join_(std::move(join)) {}

  // True when the fork took the op's fence. `chromium_browser` 0: the op's
  // browser is not open here, and its fence is released.
  bool Apply(const PageResize& resize, int chromium_browser, const std::function<void()>& change_frame) {
    ++stats_.resizes;
    bool joined = false;
    if (resize.fence_seq != 0) {
      ++stats_.fenced;
      const uint32_t right = book_.Take(resize.fence_seq);
      if (right == 0) {
        ++stats_.missing;
      } else {
        const uint32_t frames =
            resize.deadline_frames < kMaxFenceDeadlineFrames ? resize.deadline_frames : kMaxFenceDeadlineFrames;
        joined = chromium_browser != 0 && join_ && join_(chromium_browser, right, frames) == 1;
        inbox_->Release(right);  // the fork holds its own right; the host's goes now
        if (joined) ++stats_.joined;
      }
    }
    if (change_frame) change_frame();
    return joined;
  }

  const Stats& stats() const { return stats_; }
  const FenceBook& book() const { return book_; }

 private:
  FenceInbox* inbox_;
  FenceBook book_;
  Join join_;
  Stats stats_;
};

#if defined(__APPLE__)
// What cmux sends: one fence right and its seq.
#pragma pack(push, 4)
struct FenceMessage {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t fence;
  uint64_t seq;
};
#pragma pack(pop)

// cmux's send (the remote shim): a copy of the send right `fence` to
// `channel`, with a zero timeout, so it never waits. False when it was not
// sent (a full queue, a dead port); the copy is then released and the
// caller's right stays as it was.
inline bool SendFence(mach_port_t channel, mach_port_t fence, uint64_t seq) {
  FenceMessage message = {};
  message.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, MACH_MSGH_BITS_COMPLEX);
  message.header.msgh_size = sizeof message;
  message.header.msgh_remote_port = channel;
  message.header.msgh_id = kFenceMessageID;
  message.body.msgh_descriptor_count = 1;
  message.fence.name = fence;
  message.fence.disposition = MACH_MSG_TYPE_COPY_SEND;
  message.fence.type = MACH_MSG_PORT_DESCRIPTOR;
  message.seq = seq;
  const kern_return_t result = mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof message, 0,
                                        MACH_PORT_NULL, 0, MACH_PORT_NULL);
  if (result == MACH_MSG_SUCCESS) return true;
  // A send that failed after the kernel copied the rights in returns them
  // to this task (a pseudo-receive): destroying the message drops the copies.
  if (result == MACH_SEND_TIMED_OUT || result == MACH_SEND_INTERRUPTED) mach_msg_destroy(&message.header);
  return false;
}

// The host's inbox: the receive right checked in under `name`
// (--resize-fence), queue limit kFenceQueueLimit; nullptr when `name` is
// empty or cannot be checked in (host_resize.mm).
std::unique_ptr<FenceInbox> CheckInFenceInbox(const std::string& name);
#endif

}  // namespace cmux_host
