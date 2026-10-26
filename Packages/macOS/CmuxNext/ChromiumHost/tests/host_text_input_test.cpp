// Checks the Chromium Host's text input pushes (src/host_text_input.{h,mm},
// task p01-process-044) alone and through the dispatcher
// (src/host_dispatch.mm) with a fake shim: the fork's state is read with its
// size; the text keeps 100 UTF-16 units around the selection and the
// composition and never splits a surrogate pair; the wire fields round-trip
// to the fork's struct; the several notifications of one keystroke go out as
// one TEXT_INPUT_STATE, an unchanged state as none; only a browser cmux
// watches is pushed, under cmux's id, until cmux unwatches it or it closes.
// Run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"
#include "host_text_input.h"

#include "generated/host_dispatch.inc"

namespace {

using namespace cmux_host;
using cmux_host::control::Message;
using Writer = cmux_host::control::TlvWriter;

constexpr int32_t kMinted = 1 << 20;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

std::vector<uint16_t> Units(const std::u16string& text) {
  return std::vector<uint16_t>(text.begin(), text.end());
}

// A fork state over `storage` (kept alive by the caller).
struct ForkState {
  std::vector<int> rects;
  std::vector<uint16_t> text;
  ForkTextInputState fork{};
  ForkState(int type, int selection_start, int selection_end, std::vector<uint16_t> field_text, int offset = 0) {
    text = std::move(field_text);
    fork.size = static_cast<int>(sizeof(ForkTextInputState));
    fork.input_type = type;
    fork.selection_start = selection_start;
    fork.selection_end = selection_end;
    fork.composition_start = -1;
    fork.composition_end = -1;
    fork.text = text.empty() ? nullptr : text.data();
    fork.text_length = static_cast<int>(text.size());
    fork.text_offset = offset;
  }
  void Compose(int start, int end, std::vector<int> char_rects) {
    rects = std::move(char_rects);
    fork.composition_start = start;
    fork.composition_end = end;
    fork.composition_rects = rects.data();
    fork.composition_rect_count = static_cast<int>(rects.size() / 4);
  }
};

// The fake shim: the watch the dispatcher set.
struct Shim {
  std::vector<std::string> calls;
  HostContext* host = nullptr;
  void (*fn)(void*, int, const void*) = nullptr;
  void* context = nullptr;
  int watched = 0;
  const ForkState* current = nullptr;  // what the fork reports at once on a watch
  int live = 0;
} shim;

void Emit(int kind, int browser, int request) {
  HostContext::OnShimEvent(shim.host, kind, browser, request, 0, 0, "", "");
}

}  // namespace

extern "C" {
const char* cmux_shim_abi_id(void) { return "abi"; }
int cmux_shim_fork_api_version(void) { return 30; }
void cmux_shim_set_focus_request_handler(cmux_shim_focus_request_fn) {}
void cmux_shim_set_window_request_handler(cmux_shim_window_request_fn) {}
void cmux_shim_set_unhandled_key_handler(cmux_shim_key_fn) {}
void cmux_shim_devtools_set_key_handler(cmux_shim_key_fn) {}
int cmux_shim_create_window(int request, void*, int, int, const char*, const char*) {
  ++shim.live;
  Emit(CMUX_SHIM_AFTER_CREATED, 3, request);
  return 1;
}
int cmux_shim_browser_text_input_watch(int browser_id, void (*fn)(void* context, int browser_id, const void* state),
                                       void* context) {
  shim.calls.push_back("watch " + std::to_string(browser_id) + (fn ? " on" : " off"));
  if (browser_id != 3) return 0;  // the only browser the fake fork has
  shim.fn = fn;
  shim.context = context;
  shim.watched = fn ? browser_id : 0;
  if (fn && shim.current) fn(context, browser_id, &shim.current->fork);  // the fork reports at once
  return 1;
}
char* cmux_shim_tab_navigation_state(int) { return nullptr; }
void cmux_shim_free(char* s) { std::free(s); }
int cmux_shim_live_browser_count(void) { return shim.live; }
}

namespace {

struct Delegate : HostDelegate {
  std::vector<std::string> calls;
  void Initialize(InitializeRequest) override { calls.push_back("initialize"); }
  void Quit() override { calls.push_back("quit"); }
  void BrowserClosed() override { calls.push_back("closed"); }
  void BadMessage(const std::string& what) override { calls.push_back("bad " + what); }
};

struct Views : PageViews {
  int view = 0;
  void* Open(uint64_t) override { return &view; }
  void Close(uint64_t) override {}
};

Message Op(uint16_t op, uint32_t token, const Writer& w) {
  Message m;
  m.op = op;
  m.token = token;
  m.fields = w.fields();
  return m;
}

// The UI thread's queue: the dispatcher's flushes wait here until Turn().
struct Fixture {
  std::vector<Message> sent;
  std::vector<std::function<void()>> queued;
  Delegate delegate;
  Views views;
  HostContext host{[this](const Message& m) {
                     sent.push_back(m);
                     return true;
                   },
                   delegate, views, nullptr, [this](std::function<void()> task) { queued.push_back(std::move(task)); }};
  Fixture() {
    shim = Shim();
    shim.host = &host;
    host.Attach();
    Writer hello;
    hello.Str(kWireID);
    hello.Str(kShimAbiID);
    host.OnMessages({Op(control::kOpHello, 0, hello)});
    Writer init;
    for (const char* path : {"/fw", "/app", "/helper", "/root"}) init.Str(path);
    init.Str(nullptr);
    init.I32(0);
    init.Str(nullptr);
    init.Str(nullptr);
    init.StrList(nullptr, 0);
    host.OnMessages({Op(kOpInitialize, 1, init)});
    host.Resume();
    Writer create;
    create.I32(kMinted);
    create.I32(42);
    create.ViewToken(9);
    create.I32(800);
    create.I32(600);
    create.Str("https://a/");
    create.Str(nullptr);
    host.OnMessages({Op(kOpCreateWindow, 2, create)});
    sent.clear();
  }
  void Watch(int32_t browser, int32_t on, uint32_t token) {
    Writer w;
    w.I32(browser);
    w.I32(on);
    host.OnMessages({Op(kOpTextInputWatch, token, w)});
  }
  // Runs the queued tasks, as the UI thread does after the renderer's messages.
  void Turn() {
    std::vector<std::function<void()>> tasks;
    tasks.swap(queued);
    for (auto& task : tasks) task();
  }
  // The TEXT_INPUT_STATEs sent since the last call; other messages as "op N" or "ack N".
  std::vector<TextInputState> States(std::vector<std::string>* others = nullptr, std::vector<int32_t>* browsers = nullptr) {
    std::vector<TextInputState> states;
    for (const Message& m : sent) {
      if (m.op != kOpTextInputState) {
        if (others) others->push_back(m.op == kOpAck ? "ack " + std::to_string(m.token) : "op " + std::to_string(m.op));
        continue;
      }
      int32_t browser = 0;
      TextInputState state;
      Check(DecodeTextInputState(m.fields, &browser, &state), "a pushed state decodes");
      if (browsers) browsers->push_back(browser);
      states.push_back(std::move(state));
    }
    sent.clear();
    return states;
  }
};

void ReadsTheForkStruct() {
  ForkState f(1, 2, 4, Units(u"hello"), 10);
  f.Compose(2, 4, {1, 2, 3, 4, 5, 6, 7, 8});
  f.fork.input_mode = 3;
  f.fork.input_flags = 5;
  f.fork.caret[0] = 9;
  f.fork.caret[3] = 16;
  TextInputState s;
  Check(ReadForkTextInputState(&f.fork, &s), "an API 30 struct reads");
  Check(s.type == 1 && s.mode == 3 && s.flags == 5 && s.selection_start == 2 && s.selection_end == 4,
        "type, mode, flags and selection");
  Check(s.composition_start == 2 && s.composition_end == 4 && s.composition_rects == std::vector<int32_t>({1, 2, 3, 4, 5, 6, 7, 8}),
        "composition range and per-character rects");
  Check(s.caret == std::array<int32_t, 4>({9, 0, 0, 16}), "caret rect");
  Check(s.text == Units(u"hello") && s.text_offset == 10, "text and its field offset");

  ForkState old = f;
  old.fork.size = static_cast<int>(sizeof(ForkTextInputState)) - 4;
  TextInputState untouched;
  untouched.type = 7;
  Check(!ReadForkTextInputState(&old.fork, &untouched) && untouched.type == 7, "a struct older than API 30 is refused");
  ForkState bad = f;
  bad.fork.composition_rects = nullptr;
  Check(!ReadForkTextInputState(&bad.fork, &untouched), "rects counted but absent are refused");
  bad = f;
  bad.fork.text_length = -1;
  Check(!ReadForkTextInputState(&bad.fork, &untouched), "a negative text length is refused");
  Check(!ReadForkTextInputState(nullptr, &untouched), "no state is refused");

  ForkState many(1, 0, 0, {});
  many.Compose(0, kMaxCompositionRects + 5, std::vector<int>(static_cast<size_t>(kMaxCompositionRects + 5) * 4, 1));
  Check(ReadForkTextInputState(&many.fork, &s) && s.composition_rects.size() == static_cast<size_t>(kMaxCompositionRects) * 4,
        "at most kMaxCompositionRects rects");
}

void TrimsToTheSelectionContext() {
  std::u16string field(1000, u'a');
  for (size_t i = 0; i < field.size(); ++i) field[i] = static_cast<char16_t>(u'a' + i % 26);
  {
    TextInputState s;
    s.selection_start = 500;
    s.selection_end = 510;
    s.text = Units(field);
    TrimToSelectionContext(&s);
    Check(s.text_offset == 400 && s.text.size() == 210 && s.text.front() == field[400] && s.text.back() == field[609],
          "100 units before the selection and after it");
  }
  {
    TextInputState s;
    s.selection_start = 500;
    s.selection_end = 500;
    s.composition_start = 480;
    s.composition_end = 500;
    s.text = Units(field.substr(300));
    s.text_offset = 300;
    TrimToSelectionContext(&s);
    Check(s.text_offset == 380 && s.text.size() == 220, "the window covers the composition too, in field offsets");
  }
  {
    TextInputState s;
    s.selection_start = 20;
    s.selection_end = 990;
    s.text = Units(field);
    TrimToSelectionContext(&s);
    Check(s.text_offset == 0 && s.text.size() == 1000, "clamped to the text the page sent");
  }
  {
    TextInputState s;
    s.text = Units(field);
    s.text_offset = 5;
    TrimToSelectionContext(&s);
    Check(s.text.empty() && s.text_offset == 0, "no selection or composition keeps no text");
  }
  {
    // U+1F600 at units 399-400 (from would cut it) and 610-611 (to would cut it).
    std::vector<uint16_t> text = Units(field);
    text[399] = 0xD83D;
    text[400] = 0xDE00;
    text[609] = 0xD83D;
    text[610] = 0xDE00;
    TextInputState s;
    s.selection_start = 500;
    s.selection_end = 510;
    s.text = text;
    TrimToSelectionContext(&s);
    Check(s.text_offset == 399 && s.text.front() == 0xD83D && s.text.size() == 212 && s.text.back() == 0xDE00,
          "both ends take a cut surrogate pair whole");
  }
  {
    std::vector<uint16_t> text(kMaxTextInputUnits + 500, u'x');
    text[kMaxTextInputUnits - 1] = 0xD83D;
    text[kMaxTextInputUnits] = 0xDE00;
    TextInputState s;
    s.selection_start = 0;
    s.selection_end = static_cast<int32_t>(text.size());
    s.text = text;
    TrimToSelectionContext(&s);
    Check(s.text.size() == static_cast<size_t>(kMaxTextInputUnits) - 1 && s.text.back() == u'x',
          "a selection over the bound keeps its start and leaves out a pair the bound cuts");
  }
}

void RoundTripsTheWire() {
  ForkState f(2, 1, 3, Units(u"pa\U0001F600s"), 4);
  f.Compose(1, 3, {10, 20, 8, 16, 18, 20, 8, 16});
  f.fork.caret[0] = 26;
  f.fork.caret[1] = 20;
  f.fork.caret[2] = 1;
  f.fork.caret[3] = 16;
  TextInputState s;
  Check(ReadForkTextInputState(&f.fork, &s), "the state reads");
  int32_t browser = 0;
  TextInputState decoded;
  Check(DecodeTextInputState(EncodeTextInputState(kMinted, s), &browser, &decoded), "the fields decode");
  Check(browser == kMinted && decoded == s, "every field round-trips");
  const ForkTextInputState view = ForkViewOf(decoded);
  TextInputState again;
  Check(ReadForkTextInputState(&view, &again) && again == s, "the fork view gives the same state to fn");

  std::vector<control::Field> fields = EncodeTextInputState(1, s);
  fields.back().bytes.push_back('x');
  Check(!DecodeTextInputState(fields, &browser, &decoded), "text of an odd byte count is refused");
  fields = EncodeTextInputState(1, s);
  fields[8].bytes.push_back('x');
  Check(!DecodeTextInputState(fields, &browser, &decoded), "rects that are not 4 values each are refused");
  fields = EncodeTextInputState(1, s);
  fields.pop_back();
  Check(!DecodeTextInputState(fields, &browser, &decoded), "a missing field is refused");
}

void OnePushPerTurn() {
  std::vector<std::function<void()>> queued;
  std::vector<std::pair<int, TextInputState>> pushed;
  TextInputPushes pushes([&](std::function<void()> task) { queued.push_back(std::move(task)); },
                         [&](int browser, const TextInputState& state) { pushed.emplace_back(browser, state); });
  auto turn = [&] {
    std::vector<std::function<void()>> tasks;
    tasks.swap(queued);
    for (auto& task : tasks) task();
  };
  TextInputState typed;
  typed.type = 1;
  pushes.Changed(3, typed);
  turn();
  Check(pushed.empty(), "a browser nobody watches is not pushed");

  Check(pushes.Watch(3) && pushes.Watch(4), "watched");
  // One IME keystroke: Chromium's text input state, selection and composition range, each its own task.
  typed.selection_start = typed.selection_end = 1;
  pushes.Changed(3, typed);
  typed.composition_start = 0;
  typed.composition_end = 1;
  pushes.Changed(3, typed);
  typed.composition_rects = {0, 0, 8, 16};
  pushes.Changed(3, typed);
  Check(queued.size() == 1, "one flush is scheduled per turn");
  turn();
  Check(pushed.size() == 1 && pushed[0].first == 3 && pushed[0].second == typed,
        "three notifications of one keystroke are one push of the last state");
  Check(pushes.changes() == 3 && pushes.pushes() == 1, "counted");

  pushed.clear();
  pushes.Changed(3, typed);
  turn();
  Check(pushed.empty(), "a state equal to the last push is not pushed again");

  TextInputState other;
  other.type = 2;
  pushes.Changed(4, other);
  typed.selection_start = typed.selection_end = 2;
  pushes.Changed(3, typed);
  turn();
  Check(pushed.size() == 2 && pushed[0].first == 4 && pushed[1].first == 3, "browsers push in the order they changed");

  pushed.clear();
  Check(pushes.Watch(3), "watched again");
  pushes.Changed(3, typed);
  turn();
  Check(pushed.size() == 1, "a new watch pushes its first state even when unchanged");

  pushed.clear();
  pushes.Changed(3, other);
  pushes.Forget(3);
  turn();
  Check(pushed.empty() && !pushes.watching(3), "a forgotten browser's waiting state is dropped");

  {
    TextInputPushes bounded(nullptr, [](int, const TextInputState&) {});
    for (size_t i = 0; i < kMaxTextInputWatches; ++i) bounded.Watch(static_cast<int>(i));
    Check(!bounded.Watch(-1) && bounded.watches() == kMaxTextInputWatches, "watches are bounded");
  }
  {
    int count = 0;
    TextInputPushes immediate(nullptr, [&](int, const TextInputState&) { ++count; });
    immediate.Watch(1);
    immediate.Changed(1, typed);
    Check(count == 1, "with no schedule a change goes out at once");
  }
  {
    std::vector<std::function<void()>> late;
    int count = 0;
    {
      TextInputPushes gone([&](std::function<void()> task) { late.push_back(std::move(task)); },
                           [&](int, const TextInputState&) { ++count; });
      gone.Watch(1);
      gone.Changed(1, typed);
    }
    for (auto& task : late) task();
    Check(count == 0, "a flush that runs after its pushes are gone does nothing");
  }
}

void DispatcherPushesWatchedBrowsers() {
  Fixture f;
  ForkState focused(1, 3, 3, Units(u"abc"));
  shim.current = &focused;
  f.Watch(kMinted, 1, 7);
  Check(shim.calls == std::vector<std::string>({"watch 3 on"}), "cmux's id maps to Chromium's for the shim watch");
  std::vector<std::string> others;
  Check(f.States(&others).empty() && others == std::vector<std::string>({"ack 7"}),
        "the watch is acked; its first state waits for the turn's flush");
  f.Turn();
  std::vector<int32_t> browsers;
  std::vector<TextInputState> states = f.States(nullptr, &browsers);
  Check(states.size() == 1 && browsers == std::vector<int32_t>({kMinted}) && states[0].type == 1 &&
            states[0].text == Units(u"abc"),
        "the current state goes out under cmux's id");

  // One keystroke of a Japanese IME: three fork notifications, one push.
  ForkState composing(1, 4, 4, Units(u"abcか"));
  composing.Compose(3, 4, {30, 0, 12, 16});
  shim.fn(shim.context, 3, &focused.fork);
  shim.fn(shim.context, 3, &composing.fork);
  composing.fork.caret[0] = 42;
  composing.fork.caret[3] = 16;
  shim.fn(shim.context, 3, &composing.fork);
  f.Turn();
  states = f.States();
  Check(states.size() == 1 && states[0].composition_start == 3 && states[0].composition_rects == std::vector<int32_t>({30, 0, 12, 16}) &&
            states[0].caret[0] == 42,
        "<= 1 state message per IME keystroke, with the composition rects and caret in page view points");

  f.Watch(kMinted, 0, 8);
  Check(shim.calls.back() == "watch 3 off" && shim.fn == nullptr, "unwatch stops the fork's watch");
  others.clear();
  f.States(&others);
  Check(others == std::vector<std::string>({"ack 8"}), "the unwatch is acked");

  shim.current = nullptr;
  f.Watch(kMinted, 1, 0);
  void (*fn)(void*, int, const void*) = shim.fn;
  void* context = shim.context;
  Emit(CMUX_SHIM_BEFORE_CLOSE, 3, 0);
  f.sent.clear();
  fn(context, 3, &composing.fork);
  f.Turn();
  Check(f.States().empty(), "a closed browser is no longer pushed");

  f.Watch(77, 1, 9);
  others.clear();
  f.States(&others);
  Check(others == std::vector<std::string>({"ack 9"}) && !f.host.text_input().watching(77),
        "a watch the shim refuses (unknown browser, older fork) is acked and not kept");
  Check(f.delegate.calls == std::vector<std::string>({"initialize", "closed"}), "no bad message so far");
}

void MalformedWatches() {
  {
    Fixture f;
    Writer w;
    w.I32(3);
    f.host.OnMessages({Op(kOpTextInputWatch, 0, w)});
    Check(f.delegate.calls.back() == "bad a malformed text input watch", "a watch without its flag is bad");
  }
  {
    Fixture f;
    f.Watch(3, 2, 0);
    Check(f.delegate.calls.back() == "bad a malformed text input watch", "a watch flag other than 0 or 1 is bad");
  }
}

}  // namespace

int main() {
  ReadsTheForkStruct();
  TrimsToTheSelectionContext();
  RoundTripsTheWire();
  OnePushPerTurn();
  DispatcherPushesWatchedBrowsers();
  MalformedWatches();
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host-text-input tests: ok");
  return EXIT_SUCCESS;
}
