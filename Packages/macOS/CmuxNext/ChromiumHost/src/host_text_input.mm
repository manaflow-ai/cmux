// The Chromium Host's text input pushes (host_text_input.h). No CEF and no
// AppKit, so the dispatcher's test compiles it as C++.

#include "host_text_input.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>

namespace cmux_host {
namespace {

bool IsHighSurrogate(uint16_t unit) {
  return unit >= 0xD800 && unit <= 0xDBFF;
}
bool IsLowSurrogate(uint16_t unit) {
  return unit >= 0xDC00 && unit <= 0xDFFF;
}

}  // namespace

bool ReadForkTextInputState(const void* fork_state, TextInputState* out) {
  if (fork_state == nullptr) return false;
  const auto* fork = static_cast<const ForkTextInputState*>(fork_state);
  if (fork->size < static_cast<int>(sizeof(ForkTextInputState))) return false;
  if (fork->composition_rect_count < 0 || (fork->composition_rect_count > 0 && !fork->composition_rects)) return false;
  if (fork->text_length < 0 || (fork->text_length > 0 && !fork->text)) return false;
  TextInputState state;
  state.type = fork->input_type;
  state.mode = fork->input_mode;
  state.flags = fork->input_flags;
  state.selection_start = fork->selection_start;
  state.selection_end = fork->selection_end;
  state.composition_start = fork->composition_start;
  state.composition_end = fork->composition_end;
  const int rects = std::min(fork->composition_rect_count, kMaxCompositionRects);
  state.composition_rects.assign(fork->composition_rects, fork->composition_rects + static_cast<size_t>(rects) * 4);
  std::copy(fork->caret, fork->caret + 4, state.caret.begin());
  state.text.assign(fork->text, fork->text + fork->text_length);
  state.text_offset = fork->text_offset;
  *out = std::move(state);
  return true;
}

void TrimToSelectionContext(TextInputState* state) {
  int64_t first = INT64_MAX;
  int64_t last = INT64_MIN;
  auto anchor = [&](int32_t start, int32_t end) {
    if (start < 0 || end < start) return;
    first = std::min<int64_t>(first, start);
    last = std::max<int64_t>(last, end);
  };
  anchor(state->selection_start, state->selection_end);
  anchor(state->composition_start, state->composition_end);
  const int64_t text_start = state->text_offset;
  const int64_t text_end = text_start + static_cast<int64_t>(state->text.size());
  if (first > last) {
    state->text.clear();
    state->text_offset = 0;
    return;
  }
  int64_t from = std::clamp<int64_t>(first - kExtraCharsBeforeAndAfterSelection, text_start, text_end);
  const auto at = [&](int64_t offset) { return state->text[static_cast<size_t>(offset - text_start)]; };
  // Neither end cuts a surrogate pair: `from` takes its high half in, `to`
  // takes the low half in while under the bound, else leaves the pair out.
  if (from > text_start && from < text_end && IsLowSurrogate(at(from)) && IsHighSurrogate(at(from - 1))) --from;
  int64_t to = std::clamp<int64_t>(last + kExtraCharsBeforeAndAfterSelection, from, text_end);
  to = std::min<int64_t>(to, from + kMaxTextInputUnits);
  if (to > from && to < text_end && IsHighSurrogate(at(to - 1)) && IsLowSurrogate(at(to))) {
    to += to - from < kMaxTextInputUnits ? 1 : -1;
  }
  std::vector<uint16_t> kept(state->text.begin() + (from - text_start), state->text.begin() + (to - text_start));
  state->text = std::move(kept);
  state->text_offset = static_cast<int32_t>(from);
}

std::vector<control::Field> EncodeTextInputState(int32_t browser, const TextInputState& state) {
  control::TlvWriter w;
  w.I32(browser);
  w.I32(state.type);
  w.I32(state.mode);
  w.I32(state.flags);
  w.I32(state.selection_start);
  w.I32(state.selection_end);
  w.I32(state.composition_start);
  w.I32(state.composition_end);
  w.I32Array(state.composition_rects.data(), state.composition_rects.size());
  for (int32_t value : state.caret) w.I32(value);
  w.I32(state.text_offset);
  std::string text;
  text.reserve(state.text.size() * 2);
  for (uint16_t unit : state.text) control::PutLE(&text, unit, 2);
  w.Bytes(text.data(), text.size());
  return w.Take();
}

bool DecodeTextInputState(std::vector<control::Field> fields, int32_t* browser, TextInputState* out) {
  control::TlvReader r(std::move(fields));
  TextInputState state;
  const int32_t id = r.I32();
  state.type = r.I32();
  state.mode = r.I32();
  state.flags = r.I32();
  state.selection_start = r.I32();
  state.selection_end = r.I32();
  state.composition_start = r.I32();
  state.composition_end = r.I32();
  const std::string rects = r.Bytes();
  for (int32_t& value : state.caret) value = r.I32();
  state.text_offset = r.I32();
  const std::string text = r.Bytes();
  if (!r.ok() || !r.AtEnd() || rects.size() % 16 != 0 || rects.size() / 16 > static_cast<size_t>(kMaxCompositionRects) ||
      text.size() % 2 != 0 || text.size() / 2 > static_cast<size_t>(kMaxTextInputUnits)) {
    return false;
  }
  const std::string_view rect_bytes(rects);
  state.composition_rects.resize(rects.size() / 4);
  for (size_t i = 0; i < state.composition_rects.size(); ++i) {
    state.composition_rects[i] = static_cast<int32_t>(static_cast<uint32_t>(control::GetLE(rect_bytes.substr(i * 4, 4))));
  }
  const std::string_view text_bytes(text);
  state.text.resize(text.size() / 2);
  for (size_t i = 0; i < state.text.size(); ++i) {
    state.text[i] = static_cast<uint16_t>(control::GetLE(text_bytes.substr(i * 2, 2)));
  }
  *browser = id;
  *out = std::move(state);
  return true;
}

ForkTextInputState ForkViewOf(const TextInputState& state) {
  ForkTextInputState view{};
  view.size = static_cast<int>(sizeof(ForkTextInputState));
  view.input_type = state.type;
  view.input_mode = state.mode;
  view.input_flags = state.flags;
  view.selection_start = state.selection_start;
  view.selection_end = state.selection_end;
  view.composition_start = state.composition_start;
  view.composition_end = state.composition_end;
  view.composition_rects = state.composition_rects.empty() ? nullptr : state.composition_rects.data();
  view.composition_rect_count = static_cast<int>(state.composition_rects.size() / 4);
  std::copy(state.caret.begin(), state.caret.end(), view.caret);
  view.text = state.text.empty() ? nullptr : state.text.data();
  view.text_length = static_cast<int>(state.text.size());
  view.text_offset = state.text_offset;
  return view;
}

TextInputPushes::TextInputPushes(RequestFrame request_frame, Push push)
    : request_frame_(std::move(request_frame)), push_(std::move(push)) {}

TextInputPushes::~TextInputPushes() {
  *alive_ = false;
}

void TextInputPushes::Watch(int browser) {
  watched_[browser].pushed.reset();
}

void TextInputPushes::Forget(int browser) {
  watched_.erase(browser);
  std::erase(order_, browser);
}

void TextInputPushes::Changed(int browser, TextInputState state) {
  auto found = watched_.find(browser);
  if (found == watched_.end()) return;
  ++stats_.changes;
  if (!found->second.waiting) order_.push_back(browser);
  found->second.waiting = std::move(state);
  if (!request_frame_) return Flush();
  if (frame_requested_) return;
  frame_requested_ = true;
  request_frame_([this, alive = alive_] {
    if (*alive) Flush();
  });
}

void TextInputPushes::Flush() {
  frame_requested_ = false;
  std::vector<int> order;
  order.swap(order_);
  if (!order.empty()) ++stats_.frames;
  for (int browser : order) {
    auto found = watched_.find(browser);
    if (found == watched_.end() || !found->second.waiting) continue;
    Watched& watched = found->second;
    TextInputState state = std::move(*watched.waiting);
    watched.waiting.reset();
    if (watched.pushed == state) continue;
    if (!push_(browser, state)) {
      // cmux did not get it: its last state is unknown, so the next change goes out even when equal.
      ++stats_.unsent;
      watched.pushed.reset();
      continue;
    }
    ++stats_.pushes;
    watched.pushed = std::move(state);
  }
}

}  // namespace cmux_host
