// The wire between cmux and the Chromium host app (prototype behind
// `browserHost.helperPrototype`; plans/cmux-next/cef-helper-app-DESIGN.md).
// Needs no CEF: scripts/cmux-next/tests/chromium-host-wire.test.sh compiles
// it alone. CmuxNextBrowser mirrors it in ChromiumHostFrame.swift; the golden
// bytes in ../tests/chromium_host_wire_test.cpp and
// ChromiumHostFrameTests.swift are the same. CI runs neither the C++ test nor
// this script (no new CI tests): whoever changes either side runs both.
//
// A frame is a 64-byte little-endian header and `payload` bytes after it
// (UTF-8 text: a URL, a title). Fields by kind are listed with each kind.
// Times are CLOCK_UPTIME_RAW nanoseconds, one clock for both processes.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace cmux_host {

inline constexpr size_t kHeaderSize = 64;
// Longer payloads end the connection: no kind carries more than a URL.
inline constexpr uint32_t kMaxPayload = 64 * 1024;
// Seconds a host may take to end after kQuit or EOF before it ends by force
// (it _exits itself; cmux SIGKILLs it): ChromiumHostFrame.quitLimit.
inline constexpr int kQuitLimitSeconds = 15;
// The oldest fork API the host runs on: layer hosting (26) and the resize
// sync (27), so its Chromium never holds a commit for a resize on its own.
// cmux starts it with the switch set of this API (ChromiumHostConfiguration,
// CEFSwitches.resizeSyncForkAPI: no AsyncLiveResize).
inline constexpr int kMinForkAPI = 27;
// Frames the reader may hand to the UI thread that it has not run yet (and
// frames held before the UI thread exists): ChromiumHostConnection.frameBacklog.
inline constexpr size_t kFrameBacklog = 4096;

// Exit statuses of a host that could not start. cmux does not restart such a
// host (ChromiumHostExit.startFailures): a new one would fail the same way.
inline constexpr int kExitNoWire = 64;          // fds 3 and 4 are not open
inline constexpr int kExitFrameworkLoad = 65;   // cef_load_library failed
inline constexpr int kExitForkAPI = 66;         // fork API below kMinForkAPI
inline constexpr int kExitInitialize = 67;      // CefInitialize failed

enum Kind : uint32_t {
  // cmux -> host
  kNavigate = 1,   // payload url
  kGeometry = 2,   // v0 width, v1 height (points), v2 screen x, v3 screen y (bottom left), v4 scale * 1000
                   // (informational: the host's window takes the scale of the screen it is placed on;
                   // cmux sends the geometry again when the window moves or changes screen or scale)
  kMouse = 3,      // v0 x, v1 y (points, top left), v2 phase (0 move, 1 down, 2 up, 3 exit), v3 button
                   // (0 left, 1 middle, 2 right), v4 click count, flags = NSEventModifierFlags, t0 event time
  kWheel = 4,      // v0 x, v1 y, v2 dx, v3 dy (pixels), flags, t0
  kKey = 5,        // v0 phase (0 down, 1 up, 2 flags changed), v1 key code, v2 repeat, flags, ch, unmod, t0
  kFocus = 6,      // v0 1 focused, 0 not
  kPing = 7,       // t0 cmux send time; the host answers kPong
  kStats = 8,      // seq request id; the host answers kStatsReply with the same seq
  kQuit = 9,
  kEdit = 10,      // v0 0 copy, 1 cut, 2 paste, 3 select all, 4 undo, 5 redo
  // host -> cmux
  kReady = 101,         // v0 fork API version, v1 host pid
  kContext = 102,       // v0 CAContext id (bits of a uint32)
  kAddress = 103,       // payload url (main frame)
  kTitle = 104,         // payload title
  kPong = 105,          // t0 echoed, t1 host receive time
  kStatsReply = 106,    // seq of the request; v0 input events, v1 p50, v2 p95, v3 p99, v4 max (us from cmux's
                        // event time to the host's Send*Event on its UI thread, over the last kHopWindow
                        // events), v5 frames refused (unknown kind)
  kError = 107,         // payload message
  kRendererGone = 108,  // v0 cef_termination_status_t
};

struct Header {
  uint32_t kind = 0;
  uint32_t payload = 0;
  int32_t v[6] = {0, 0, 0, 0, 0, 0};
  uint64_t flags = 0;
  uint64_t t0 = 0;
  uint64_t t1 = 0;
  uint16_t ch = 0;
  uint16_t unmod = 0;
  uint32_t seq = 0;
};

namespace detail {
template <typename T>
inline void Put(uint8_t* out, size_t offset, T value) {
  for (size_t i = 0; i < sizeof(T); ++i) out[offset + i] = static_cast<uint8_t>(static_cast<uint64_t>(value) >> (8 * i));
}
template <typename T>
inline T Get(const uint8_t* in, size_t offset) {
  uint64_t value = 0;
  for (size_t i = 0; i < sizeof(T); ++i) value |= static_cast<uint64_t>(in[offset + i]) << (8 * i);
  return static_cast<T>(value);
}
}  // namespace detail

inline void Encode(const Header& h, uint8_t out[kHeaderSize]) {
  using detail::Put;
  Put<uint32_t>(out, 0, h.kind);
  Put<uint32_t>(out, 4, h.payload);
  for (int i = 0; i < 6; ++i) Put<uint32_t>(out, 8 + 4 * i, static_cast<uint32_t>(h.v[i]));
  Put<uint64_t>(out, 32, h.flags);
  Put<uint64_t>(out, 40, h.t0);
  Put<uint64_t>(out, 48, h.t1);
  Put<uint16_t>(out, 56, h.ch);
  Put<uint16_t>(out, 58, h.unmod);
  Put<uint32_t>(out, 60, h.seq);
}

// False when the header announces a payload longer than kMaxPayload.
inline bool Decode(const uint8_t in[kHeaderSize], Header* h) {
  using detail::Get;
  h->kind = Get<uint32_t>(in, 0);
  h->payload = Get<uint32_t>(in, 4);
  for (int i = 0; i < 6; ++i) h->v[i] = static_cast<int32_t>(Get<uint32_t>(in, 8 + 4 * i));
  h->flags = Get<uint64_t>(in, 32);
  h->t0 = Get<uint64_t>(in, 40);
  h->t1 = Get<uint64_t>(in, 48);
  h->ch = Get<uint16_t>(in, 56);
  h->unmod = Get<uint16_t>(in, 58);
  h->seq = Get<uint32_t>(in, 60);
  return h->payload <= kMaxPayload;
}

// Counts the frames the reader has posted to the UI thread that have not run
// yet. Only the reader thread calls TryTake (one producer), the UI thread
// calls Done once per frame it runs.
class InFlightFrames {
 public:
  explicit constexpr InFlightFrames(size_t limit) : limit_(limit) {}
  // False when `limit` frames wait already: the UI thread has stopped running them.
  bool TryTake() {
    if (count_.load(std::memory_order_acquire) >= limit_) return false;
    count_.fetch_add(1, std::memory_order_acq_rel);
    return true;
  }
  void Done() { count_.fetch_sub(1, std::memory_order_acq_rel); }
  size_t count() const { return count_.load(std::memory_order_acquire); }

 private:
  const size_t limit_;
  std::atomic<size_t> count_{0};
};

}  // namespace cmux_host
