// Text input state the Chromium Host pushes ahead to cmux's NSTextInputClient
// (plans/cmux-next/chrome-parity/p01-process.md), so
// markedRange, selectedRange, attributedSubstringForProposedRange: and
// firstRectForCharacterRange: answer from the last push, with no sync call.
//
// Chrome sends the same facts to its out-of-process NSView as three calls of
// content/common/render_widget_host_ns_view.mojom (SetTextInputState,
// SetCompositionRangeInfo, SetTextSelection; render_widget_host_view_mac.mm)
// and still keeps SyncGetFirstRectForRange for ranges its cache misses. The
// host folds them into one TEXT_INPUT_STATE per browser per display frame,
// with the selection's text plus kExtraCharsBeforeAndAfterSelection on each
// side (Chrome's RenderFrameImpl::SyncSelectionIfRequired context), so cmux
// needs no sync call at all.
//
// Wire, next to kOpHello (chromium_host_tlv.h); none is in the generated op
// table, and the host sends TEXT_INPUT_STATE only for a browser cmux watches:
//   cmux -> host  kOpTextInputWatch  i32 browser, i32 watch (1 on, 0 off).
//                                    A token != 0 is answered by kOpReply with
//                                    i32 cmux_shim_browser_text_input_watch's
//                                    result, as in process: 0 is a refused
//                                    watch (an unknown browser, a fork without
//                                    the watch). The watch of a browser cmux
//                                    minted whose creation has not come yet is
//                                    armed, and answered, when it comes. Sent
//                                    by the remote shim's local
//                                    cmux_shim_browser_text_input_watch (014b).
//   host -> cmux  kOpTextInputState  EncodeTextInputState's fields; the remote
//                                    shim gives fn ForkViewOf(the decoded state).
//   cmux -> host  kOpTextInputStats  no fields; answered by kOpReply with
//                                    TextInputPushes::Stats as i64 changes,
//                                    pushes, frames, unsent, then i64 watches
//                                    (chromium-host-bench.py --ime).
//
// No CEF, no AppKit: scripts/cmux-next/tests/chromium-host-dispatch.test.sh
// compiles it on Linux. UI thread only, like host_dispatch.h: no lock.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <unordered_map>
#include <vector>

#include "chromium_host_tlv.h"

namespace cmux_host {

inline constexpr uint16_t kOpTextInputWatch = 0x8006;
inline constexpr uint16_t kOpTextInputState = 0x8007;
inline constexpr uint16_t kOpTextInputStats = 0x8008;

// UTF-16 units of field text kept before the selection's (and composition's)
// start and after its end.
inline constexpr int32_t kExtraCharsBeforeAndAfterSelection = 100;
// Bounds that keep one push far under the control frame (kMaxBody): a
// selection longer than this sends its first kMaxTextInputUnits units.
inline constexpr int32_t kMaxTextInputUnits = 8192;
inline constexpr int32_t kMaxCompositionRects = 1024;

// The fork's cmux_text_input_state_t (include/cef_cmux.h, API 30): offsets
// are UTF-16 units in the focused field, rects are the page view's DIP with a
// top left origin, which is cmux's ChromiumHostPageView's point space.
// Fields are only appended; `size` is the fork's sizeof.
struct ForkTextInputState {
  int size;
  int input_type;  // ui::TextInputType: 0 none, 1 text, 2 password, ...
  int input_mode;  // ui::TextInputMode
  int input_flags;  // ui::TextInputFlags
  int selection_start;  // -1 unknown; start == end is the caret
  int selection_end;
  int composition_start;  // -1, -1: no composition
  int composition_end;
  const int* composition_rects;  // x, y, width, height per composition character
  int composition_rect_count;
  int caret[4];  // x, y, width, height; all 0 when unknown
  const uint16_t* text;  // the field's text around the selection, or NULL
  int text_length;
  int text_offset;  // the field offset of text[0]
};
static_assert(sizeof(void*) != 8 || sizeof(ForkTextInputState) == 80, "the fork's API 30 layout on LP64");

struct TextInputState {
  int32_t type = 0;
  int32_t mode = 0;
  int32_t flags = 0;
  int32_t selection_start = -1;
  int32_t selection_end = -1;
  int32_t composition_start = -1;
  int32_t composition_end = -1;
  std::vector<int32_t> composition_rects;  // 4 per character
  std::array<int32_t, 4> caret = {0, 0, 0, 0};
  std::vector<uint16_t> text;  // UTF-16 units
  int32_t text_offset = 0;

  bool operator==(const TextInputState& other) const = default;
};

// The state behind the fork's pointer; false (out untouched) for a struct
// older than API 30's or inconsistent counts. Copies at most
// kMaxCompositionRects rects.
bool ReadForkTextInputState(const void* fork_state, TextInputState* out);

// Keeps the text from kExtraCharsBeforeAndAfterSelection before the first of
// the selection and composition starts to as many after the last of their
// ends, at most kMaxTextInputUnits, never splitting a surrogate pair. No
// known selection or composition keeps no text.
void TrimToSelectionContext(TextInputState* state);

// kOpTextInputState's fields: i32 browser, type, mode, flags, selection start,
// end, composition start, end; bytes rects (i32 LE, 4 per character); i32
// caret x, y, width, height; i32 text offset; bytes text (UTF-16 LE).
std::vector<control::Field> EncodeTextInputState(int32_t browser, const TextInputState& state);
// False for fields that are not EncodeTextInputState's, or over its bounds.
bool DecodeTextInputState(std::vector<control::Field> fields, int32_t* browser, TextInputState* out);

// The fork's struct over `state`'s storage, for a fn that reads
// cmux_text_input_state_t (the remote shim); valid while `state` lives
// unchanged.
ForkTextInputState ForkViewOf(const TextInputState& state);

// The watched browsers and their states. A change waits for the start of the
// next display frame, as Chrome aligns input and what it changes to the
// BeginFrame (InputHandlerProxy::DeliverInputForBeginFrame in
// third_party/blink/renderer/platform/widget/input/input_handler_proxy.cc,
// driven on macOS by ExternalBeginFrameSourceMac,
// components/viz/service/frame_sinks/external_begin_frame_source_mac.cc):
// the notifications Chromium makes within one frame (text input state,
// selection bounds, composition range: separate WidgetHost messages) go out
// as one push, and a state equal to the last one cmux got is not pushed
// again. That bounds pushes to one per browser per frame, not per keystroke:
// chromium-host-bench.py --ime counts pushes per keystroke (stats()).
class TextInputPushes {
 public:
  // Runs a task at the start of the next display frame (the host's display
  // link, browser_host_main.mm). nullptr: a change is pushed at once.
  using RequestFrame = std::function<void(std::function<void()>)>;
  // Sends one state; false when it did not go out (the channel refused it).
  using Push = std::function<bool(int browser, const TextInputState& state)>;

  struct Stats {
    uint64_t changes = 0;  // states the fork reported for watched browsers
    uint64_t pushes = 0;  // TEXT_INPUT_STATEs sent
    uint64_t frames = 0;  // frames that flushed waiting states
    uint64_t unsent = 0;  // pushes the channel refused (sent again on the next change)
  };

  TextInputPushes(RequestFrame request_frame, Push push);
  ~TextInputPushes();
  TextInputPushes(const TextInputPushes&) = delete;
  TextInputPushes& operator=(const TextInputPushes&) = delete;

  // A browser watched again pushes its next state even when it equals the
  // last one. No bound of its own: a browser stays watched only while it is
  // live (the fork refuses an unknown one; a closed one is forgotten).
  void Watch(int browser);
  // Stops pushes for the browser (also when it closed).
  void Forget(int browser);
  bool watching(int browser) const { return watched_.count(browser) != 0; }
  size_t watches() const { return watched_.size(); }

  // A new state of a watched browser (others are ignored).
  void Changed(int browser, TextInputState state);
  // Pushes every waiting state that differs from the last one cmux got for
  // its browser, in the order of their first change since the last flush.
  void Flush();

  const Stats& stats() const { return stats_; }

 private:
  struct Watched {
    std::optional<TextInputState> waiting;
    std::optional<TextInputState> pushed;  // the last state cmux got
  };

  RequestFrame request_frame_;
  Push push_;
  std::unordered_map<int, Watched> watched_;
  std::vector<int> order_;  // browsers with a waiting state, by first change
  bool frame_requested_ = false;
  // The requested frame flushes only while this object lives.
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
  Stats stats_;
};

}  // namespace cmux_host
