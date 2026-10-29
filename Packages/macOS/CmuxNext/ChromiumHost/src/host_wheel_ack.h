// WHEEL_ACK: Chromium's answer to each trackpad wheel cmux's page view sent
// (plans/cmux-next/chrome-parity/p01-process.md), so
// cmux's swipe navigation decides from it, with no page probe on the control
// channel.
//
// Chrome's history swiper decides from the same two answers its page view
// gets (chrome/browser/renderer_host/
// chrome_render_widget_host_view_mac_history_swiper.mm):
// -rendererHandledGestureScrollEvent:consumed: (GestureScrollEventAck of
// content/common/render_widget_host_ns_view.mojom) says whether the gesture's
// first scroll update scrolled anything, and -onOverscrolled: (DidOverscroll)
// whether the page leaves the overscroll to the browser
// (overscroll-behavior-x auto). Out of process, Chrome's browser sends both
// to the app shim's view; the host sends both per wheel as one event.
//
// Event (an optional event of plans/cmux-next/chromium-host-ops.json):
//   CMUX_SHIM_WHEEL_ACK = kEventWheelAck
//   browser_id  the page's browser (cmux's id)
//   request     the input seq (Header::seq) of the wheel it answers, one of
//               those the host gave the page with cmux_shim_browser_send_wheel
//               (WheelAcks pairs each fork ack with its wheel)
//   a           DIPs the page scrolled for it in hundredths: x in the low 32
//               bits, y in the high 32 (each signed)
//   b           kWheelAck* flags in the low 32 bits (with
//               kWheelAckOverscrolled, overscroll-behavior-x in bits 8-9: 0
//               auto, 1 contain, 2 none), and the accumulated overscroll's x
//               in hundredths of a DIP in the high 32 bits
// Acks of momentum wheels are not sent: momentum never starts a swipe.
//
// Capability: a host on a fork with the handler lists kWheelAcksHelloName in
// its HELLO, and from then on acks every wheel of a gesture; cmux probes the
// page itself only on a host that does not (CEFSwipeNavigation).
//
// Fork item (after API 31, PL-cef-layer), in include/cef_cmux.h:
//   typedef struct { ... ForkWheelAck's fields ... } cmux_wheel_ack_t;
//   int cmux_set_wheel_ack_handler(
//       void (*fn)(void* ctx, int browser_id, const cmux_wheel_ack_t* ack),
//       void* ctx);  // NULL fn clears it; returns 1 when set
// The fork calls fn on the UI thread once per wheel cmux_browser_send_wheel
// sent, a page's in the order it sent them, when Chromium is done with it: at the ack of the GestureScrollUpdate
// it made (RenderWidgetHostViewMac::GestureEventAck), with the
// DidOverscrollParams that came with that ack, or at the wheel's own ack when
// it made no update (a script's preventDefault, a phase edge with no delta;
// RenderWidgetHostViewMac::WheelEventAck).
//
// No CEF, no AppKit: scripts/cmux-next/tests/chromium-host-dispatch.test.sh
// compiles it on Linux. UI thread only, like host_dispatch.h: no lock.
#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <unordered_map>

namespace cmux_host {

// CMUX_SHIM_WHEEL_ACK (plans/cmux-next/chromium-host-ops.json, optional_events).
inline constexpr int kEventWheelAck = 56;
// The name a host lists in its HELLO's exports once the fork reports each
// wheel's ack (CEFAttachedHost.wheelAcksHelloName in cmux).
inline constexpr char kWheelAcksHelloName[] = "cmux_host_wheel_acks";

// The fork's cmux_wheel_ack_t. Fields are only appended; `size` is the
// fork's sizeof.
struct ForkWheelAck {
  int size;
  int flags;  // kWheelAck* below: what Chromium did with the wheel
  float consumed_x;  // DIPs the page scrolled for it: the update's delta less
  float consumed_y;  // DidOverscrollParams::latest_overscroll_delta
  float overscroll_x;  // DidOverscrollParams::accumulated_overscroll, with
  float overscroll_y;  // kWheelAckOverscrolled
  int overscroll_behavior_x;  // DidOverscrollParams::overscroll_behavior.x: 0 auto, 1 contain, 2 none
};
static_assert(sizeof(ForkWheelAck) == 28, "the fork's first cmux_wheel_ack_t layout");

// The fork's flags and the event's (b's low bits) are the same bits.
// The wheel made a GestureScrollUpdate, and this is its ack.
inline constexpr int32_t kWheelAckUpdate = 1 << 0;
// The page took it: the update's ack was consumed (it scrolled something), or
// a script's preventDefault took the wheel (its ack consumed, no update).
inline constexpr int32_t kWheelAckConsumed = 1 << 1;
// DidOverscroll came with it: the page had no room left that way.
inline constexpr int32_t kWheelAckOverscrolled = 1 << 2;
inline constexpr int kWheelAckBehaviorShift = 8;
inline constexpr int32_t kWheelAckFlagsMask = kWheelAckUpdate | kWheelAckConsumed | kWheelAckOverscrolled;
// overscroll-behavior-x.
inline constexpr int32_t kOverscrollAuto = 0;
inline constexpr int32_t kOverscrollContain = 1;
inline constexpr int32_t kOverscrollNone = 2;

// One ack as the host reads it.
struct WheelAck {
  int32_t flags = 0;  // kWheelAck* (kWheelAckFlagsMask)
  float consumed_x = 0;
  float consumed_y = 0;
  float overscroll_x = 0;
  int32_t overscroll_behavior_x = kOverscrollAuto;
  bool operator==(const WheelAck&) const = default;
};

// The ack behind the fork's pointer; false (out untouched) for no ack or a
// struct older than the first layout. An unknown behavior reads as none
// (the page keeps the overscroll), unknown flag bits are dropped.
inline bool ReadForkWheelAck(const void* fork_ack, WheelAck* out) {
  if (!fork_ack || !out) return false;
  const auto* ack = static_cast<const ForkWheelAck*>(fork_ack);
  if (ack->size < static_cast<int>(sizeof(ForkWheelAck))) return false;
  WheelAck read;
  read.flags = ack->flags & kWheelAckFlagsMask;
  read.consumed_x = ack->consumed_x;
  read.consumed_y = ack->consumed_y;
  read.overscroll_x = ack->overscroll_x;
  const int behavior = ack->overscroll_behavior_x;
  read.overscroll_behavior_x =
      behavior == kOverscrollAuto || behavior == kOverscrollContain ? behavior : kOverscrollNone;
  *out = read;
  return true;
}

// `value` in hundredths, rounded and clamped to int32; NaN is 0.
inline int32_t Hundredths(float value) {
  const double scaled = std::round(static_cast<double>(value) * 100.0);
  if (std::isnan(scaled)) return 0;
  if (scaled >= 2147483647.0) return INT32_MAX;
  if (scaled <= -2147483648.0) return INT32_MIN;
  return static_cast<int32_t>(scaled);
}

inline int64_t PackHundredths(float low, float high) {
  return static_cast<int64_t>((static_cast<uint64_t>(static_cast<uint32_t>(Hundredths(high))) << 32) |
                              static_cast<uint32_t>(Hundredths(low)));
}

// A WHEEL_ACK event's request, a and b (the header's comment).
struct WheelAckEvent {
  int32_t request = 0;
  int64_t a = 0;
  int64_t b = 0;
  bool operator==(const WheelAckEvent&) const = default;
};

inline WheelAckEvent EncodeWheelAck(uint32_t seq, const WheelAck& ack) {
  WheelAckEvent event;
  event.request = static_cast<int32_t>(seq);
  event.a = PackHundredths(ack.consumed_x, ack.consumed_y);
  uint32_t flags = static_cast<uint32_t>(ack.flags & kWheelAckFlagsMask);
  if (ack.flags & kWheelAckOverscrolled) {
    flags |= static_cast<uint32_t>(ack.overscroll_behavior_x & 3) << kWheelAckBehaviorShift;
  }
  const uint32_t overscroll = (ack.flags & kWheelAckOverscrolled) ? static_cast<uint32_t>(Hundredths(ack.overscroll_x)) : 0;
  event.b = static_cast<int64_t>((static_cast<uint64_t>(overscroll) << 32) | flags);
  return event;
}

// The wheels the host gave each page that Chromium has not acked yet, oldest
// first, so each fork ack (which names the browser only) carries the input
// seq cmux stamped on the wheel it answers. The host hands a wheel to
// Chromium before Chromium acks the one before it (task p01-process-042 acks
// at dispatch), so several can be in flight; the fork acks a page's wheels
// once each, in the order cmux_browser_send_wheel took them, as Chromium's
// MouseWheelEventQueue (components/input/mouse_wheel_event_queue.cc) acks its
// queue front first. So each ack answers the page's oldest unacked wheel.
class WheelAcks {
 public:
  // Unacked wheels kept per page; past it the oldest goes (a fork that
  // stopped acking), so the queue stays bounded.
  static constexpr size_t kMaxInFlight = 256;

  // `chromium_id` was given the wheel of input seq `seq` (0: cmux stamped
  // none, so nothing can name it), a momentum wheel when `momentum`.
  void Sent(int chromium_id, uint32_t seq, bool momentum) {
    std::deque<Wheel>& wheels = unacked_[chromium_id];
    if (wheels.size() >= kMaxInFlight) wheels.pop_front();
    wheels.push_back(Wheel{seq, momentum});
  }
  // The fork acked `chromium_id`'s oldest unacked wheel with `ack` (nullptr:
  // an ack the host could not read, which still answers that wheel): the
  // event for it, or nullopt when the page has no unacked wheel, the ack is
  // unreadable, or the wheel is momentum (momentum never starts a swipe) or
  // carries no seq.
  std::optional<WheelAckEvent> Acked(int chromium_id, const WheelAck* ack) {
    auto found = unacked_.find(chromium_id);
    if (found == unacked_.end()) return std::nullopt;
    const Wheel wheel = found->second.front();
    found->second.pop_front();
    if (found->second.empty()) unacked_.erase(found);
    if (!ack || wheel.momentum || wheel.seq == 0) return std::nullopt;
    return EncodeWheelAck(wheel.seq, *ack);
  }
  // The browser closed.
  void Forget(int chromium_id) { unacked_.erase(chromium_id); }
  // Pages with unacked wheels.
  size_t size() const { return unacked_.size(); }
  // `chromium_id`'s unacked wheels.
  size_t InFlight(int chromium_id) const {
    auto found = unacked_.find(chromium_id);
    return found == unacked_.end() ? 0 : found->second.size();
  }

 private:
  struct Wheel {
    uint32_t seq;
    bool momentum;
  };
  // Never holds an empty queue.
  std::unordered_map<int, std::deque<Wheel>> unacked_;
};

// The fork's cmux_set_wheel_ack_handler.
using WheelAckFn = void (*)(void* ctx, int browser_id, const void* ack);
using SetWheelAckHandlerFn = int (*)(WheelAckFn fn, void* ctx);

}  // namespace cmux_host
