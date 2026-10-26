// Text input state the Chromium Host pushes ahead to cmux's NSTextInputClient
// (plans/cmux-next/chrome-parity/p01-process.md, task p01-process-044), so
// markedRange, selectedRange, attributedSubstringForProposedRange: and
// firstRectForCharacterRange: answer from the last push, with no sync call.
//
// Chrome sends the same facts to its out-of-process NSView as three calls of
// content/common/render_widget_host_ns_view.mojom (SetTextInputState,
// SetCompositionRangeInfo, SetTextSelection; render_widget_host_view_mac.mm)
// and still keeps SyncGetFirstRectForRange for ranges its cache misses. The
// host sends them as one TEXT_INPUT_STATE per browser per UI-thread turn, and
// with the selection's text plus kExtraCharsBeforeAndAfterSelection on each
// side (Chrome's RenderFrameImpl::SyncSelectionIfRequired context) cmux needs
// no sync call at all.
//
// Wire, next to kOpHello (chromium_host_tlv.h); neither is in the generated op
// table, and the host sends TEXT_INPUT_STATE only for a browser cmux watches:
//   cmux -> host  kOpTextInputWatch  i32 browser, i32 watch (1 on, 0 off); a
//                                    token != 0 is acked. Sent by the remote
//                                    shim's local cmux_shim_browser_text_input_watch
//                                    (task 014b).
//   host -> cmux  kOpTextInputState  EncodeTextInputState's fields; the remote
//                                    shim gives fn ForkViewOf(the decoded state).
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

// UTF-16 units of field text kept before the selection's (and composition's)
// start and after its end.
inline constexpr int32_t kExtraCharsBeforeAndAfterSelection = 100;
// Bounds that keep one push far under the control frame (kMaxBody): a
// selection longer than this sends its first kMaxTextInputUnits units.
inline constexpr int32_t kMaxTextInputUnits = 8192;
inline constexpr int32_t kMaxCompositionRects = 1024;
// Browsers watched at once (each is an open page).
inline constexpr size_t kMaxTextInputWatches = 4096;

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

// The watched browsers and their states. A change waits for the flush that
// Changed schedules once per turn, so the several notifications Chromium
// makes for one keystroke (text input state, selection bounds, composition
// range: separate WidgetHost messages, each a task) go out as one push, and a
// state equal to the last one pushed is not pushed again.
class TextInputPushes {
 public:
  // Runs a task after the tasks already queued on the UI thread
  // (CefPostTask(TID_UI) in the host). nullptr: a change is pushed at once.
  using Schedule = std::function<void(std::function<void()>)>;
  using Push = std::function<void(int browser, const TextInputState& state)>;

  TextInputPushes(Schedule schedule, Push push);
  ~TextInputPushes();
  TextInputPushes(const TextInputPushes&) = delete;
  TextInputPushes& operator=(const TextInputPushes&) = delete;

  // False when kMaxTextInputWatches browsers are watched already. A browser
  // watched again pushes its next state even when it equals the last one.
  bool Watch(int browser);
  // Stops pushes for the browser (also when it closed).
  void Forget(int browser);
  bool watching(int browser) const { return watched_.count(browser) != 0; }
  size_t watches() const { return watched_.size(); }

  // A new state of a watched browser (others are ignored).
  void Changed(int browser, TextInputState state);
  // Pushes every waiting state that differs from the browser's last push, in
  // the order of their first change since the last flush.
  void Flush();

  uint64_t changes() const { return changes_; }
  uint64_t pushes() const { return pushes_; }

 private:
  struct Watched {
    std::optional<TextInputState> waiting;
    std::optional<TextInputState> pushed;
  };

  Schedule schedule_;
  Push push_;
  std::unordered_map<int, Watched> watched_;
  std::vector<int> order_;  // browsers with a waiting state, by first change
  bool flush_scheduled_ = false;
  // The scheduled flush runs only while this object lives.
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
  uint64_t changes_ = 0;
  uint64_t pushes_ = 0;
};

}  // namespace cmux_host
