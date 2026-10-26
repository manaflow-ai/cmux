// Checks the remote shim's local class (client/remote_shim_local.mm) against a
// fake transport: callbacks stay in the client, the host's pushes reach them,
// and nothing waits (scripts/cmux-next/tests/remote-shim-local.test.sh).
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "../client/remote_shim_local.h"

namespace {

int failures = 0;

void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

struct FakeTransport {
  bool accept = true;
  uint32_t token = 100;
  std::vector<std::string> sent;
  std::vector<std::string> switches;
  std::string root_cache_path;
};

bool SendInitialize(void* context, const cmux_remote::InitializeRequest& request) {
  auto* t = static_cast<FakeTransport*>(context);
  if (!t->accept) return false;
  t->sent.push_back("initialize");
  t->root_cache_path = request.root_cache_path ? request.root_cache_path : "";
  for (const char* const* it = request.switches; it && *it; ++it) t->switches.emplace_back(*it);
  return true;
}

bool SendTextInputWatch(void* context, int browser_id, bool watching) {
  auto* t = static_cast<FakeTransport*>(context);
  if (!t->accept) return false;
  t->sent.push_back("watch " + std::to_string(browser_id) + (watching ? " on" : " off"));
  return true;
}

bool SendDragSourceHandler(void* context, bool installed) {
  auto* t = static_cast<FakeTransport*>(context);
  if (!t->accept) return false;
  t->sent.push_back(installed ? "drag on" : "drag off");
  return true;
}

bool SendPasswordReveal(void* context, uint32_t token, const char* profile_cache_path, const char* id) {
  auto* t = static_cast<FakeTransport*>(context);
  if (!t->accept) return false;
  t->sent.push_back("reveal " + std::to_string(token) + " " + profile_cache_path + " " + id);
  return true;
}

uint32_t NextToken(void* context) {
  return ++static_cast<FakeTransport*>(context)->token;
}

std::string Last(const FakeTransport& t) {
  return t.sent.empty() ? std::string() : t.sent.back();
}

int schedule_calls = 0;
void Schedule(void*, int64_t) { ++schedule_calls; }

int key_calls = 0;
int Key(void*, int, void*) {
  ++key_calls;
  return 1;
}

struct EventSeen {
  void* ctx = nullptr;
  int kind = 0;
  int browser_id = 0;
  std::string s1 = "unset";
  std::string s2 = "unset";
  int calls = 0;
} event_seen;

void Event(void* ctx, int kind, int browser_id, int, int64_t, int64_t, const char* s1, const char* s2) {
  event_seen.ctx = ctx;
  event_seen.kind = kind;
  event_seen.browser_id = browser_id;
  event_seen.s1 = s1;
  event_seen.s2 = s2;
  ++event_seen.calls;
}

int user_input_calls = 0;
void UserInput(void*) { ++user_input_calls; }

struct WatchSeen {
  void* ctx = nullptr;
  int browser_id = 0;
  const void* state = nullptr;
  int calls = 0;
};
WatchSeen watch_a, watch_b;
void WatchA(void* ctx, int browser_id, const void* state) {
  watch_a = {ctx, browser_id, state, watch_a.calls + 1};
}
void WatchB(void* ctx, int browser_id, const void* state) {
  watch_b = {ctx, browser_id, state, watch_b.calls + 1};
}
// Stops its own watch from inside the callback.
void WatchStopsItself(void*, int browser_id, const void*) {
  cmux_shim_browser_text_input_watch(browser_id, nullptr, nullptr);
}

WatchSeen drag_seen;
void Drag(void* ctx, int browser_id, const void* drag) {
  drag_seen = {ctx, browser_id, drag, drag_seen.calls + 1};
}

struct RevealSeen {
  void* ctx = nullptr;
  std::string bytes;
  bool null_password = false;
  int calls = 0;
};
RevealSeen reveal_seen;
void Reveal(void* ctx, const char* password, size_t length) {
  reveal_seen.ctx = ctx;
  reveal_seen.null_password = password == nullptr;
  reveal_seen.bytes = password ? std::string(password, length) : std::string();
  ++reveal_seen.calls;
}

int InitializeShim(void* ctx) {
  static const char* const kSwitches[] = {"disable-gpu-shader-disk-cache", "lang=en-US", nullptr};
  return cmux_shim_initialize("/fw", "/app", "/helper", "/cache", nullptr, 0, "en-US", "en-US,en", kSwitches, ctx,
                              Schedule, Event, Key);
}

}  // namespace

int main() {
  FakeTransport t;
  const cmux_remote::LocalTransport transport{&t,                 SendInitialize, SendTextInputWatch,
                                              SendDragSourceHandler, SendPasswordReveal, NextToken};
  int ctx = 0, other = 0;

  // Before the host attaches nothing is sent and nothing pretends to start.
  Check(InitializeShim(&ctx) == 0, "initialize before attach returns 0");
  Check(cmux_shim_browser_text_input_watch(7, WatchA, &ctx) == 0, "watch before attach returns 0");
  Check(cmux_shim_password_reveal("/profile", "id1", Reveal, &ctx) == 0, "reveal before attach returns 0");
  Check(!cmux_remote::DeliverEvent(1, 0, 0, 0, 0, "", ""), "no event before initialize");
  cmux_shim_set_drag_source_handler(Drag, &ctx);
  Check(t.sent.empty(), "nothing sent before attach");

  // post_user_input_task never runs fn in the client: the host has its own queue.
  Check(cmux_shim_post_user_input_task(UserInput, &ctx) == 0, "post_user_input_task returns 0");
  Check(user_input_calls == 0, "post_user_input_task never runs fn");

  // Attach sends the drag handler set before it.
  cmux_remote::Attach(&transport);
  Check(Last(t) == "drag on", "attach sends the earlier drag handler");

  // initialize: one INITIALIZE with the arguments; schedule and key never run.
  Check(InitializeShim(&ctx) == 1, "initialize returns 1 once sent");
  Check(Last(t) == "initialize", "initialize sends INITIALIZE");
  Check(t.root_cache_path == "/cache", "initialize carries root_cache_path");
  Check(t.switches.size() == 2 && t.switches[1] == "lang=en-US", "initialize carries the switches");
  Check(InitializeShim(&ctx) == 0, "a second initialize returns 0");
  Check(cmux_remote::DeliverEvent(5, 9, 0, 0, 0, nullptr, "x"), "event delivered after initialize");
  Check(event_seen.ctx == &ctx && event_seen.kind == 5 && event_seen.browser_id == 9, "event_fn gets ctx and fields");
  Check(event_seen.s1.empty() && event_seen.s2 == "x", "NULL event strings arrive as empty");
  Check(schedule_calls == 0 && key_calls == 0, "schedule and key never run");

  // Text input: the watch on/off crosses the wire once; the callback stays here.
  const size_t before_watch = t.sent.size();
  Check(cmux_shim_browser_text_input_watch(7, WatchA, &ctx) == 1, "watch starts");
  Check(Last(t) == "watch 7 on", "watch start is sent");
  Check(cmux_shim_browser_text_input_watch(7, WatchB, &other) == 1, "watch replaced");
  Check(t.sent.size() == before_watch + 1, "replacing a watch sends nothing");
  int state = 0;
  Check(cmux_remote::DeliverTextInputState(7, &state), "TEXT_INPUT_STATE reaches the watch");
  Check(watch_a.calls == 0, "the replaced watch is not called");
  Check(watch_b.calls == 1 && watch_b.ctx == &other && watch_b.browser_id == 7 && watch_b.state == &state,
        "the newest watch gets its context, the browser and the state");
  Check(!cmux_remote::DeliverTextInputState(8, &state), "no watch for another browser");
  Check(cmux_shim_browser_text_input_watch(7, nullptr, nullptr) == 1, "watch stops");
  Check(Last(t) == "watch 7 off", "watch stop is sent");
  Check(!cmux_remote::DeliverTextInputState(7, &state), "a stopped watch is not called");
  const size_t before_idle_stop = t.sent.size();
  Check(cmux_shim_browser_text_input_watch(7, nullptr, nullptr) == 1, "stopping an idle watch returns 1");
  Check(t.sent.size() == before_idle_stop, "stopping an idle watch sends nothing");
  Check(cmux_shim_browser_text_input_watch(3, WatchStopsItself, &ctx) == 1, "self-stopping watch starts");
  Check(cmux_remote::DeliverTextInputState(3, &state), "self-stopping watch delivered");
  Check(Last(t) == "watch 3 off" && !cmux_remote::DeliverTextInputState(3, &state),
        "a watch may stop itself from its callback");
  t.accept = false;
  Check(cmux_shim_browser_text_input_watch(4, WatchA, &ctx) == 0, "a watch the transport refused returns 0");
  t.accept = true;
  Check(!cmux_remote::DeliverTextInputState(4, &state), "a refused watch is not kept");

  // Drag source: DRAG_START reaches the handler; NULL restores Chromium's drag.
  int drag = 0;
  Check(cmux_remote::DeliverDragStart(2, &drag), "DRAG_START reaches the handler");
  Check(drag_seen.calls == 1 && drag_seen.ctx == &ctx && drag_seen.browser_id == 2 && drag_seen.state == &drag,
        "the drag handler gets its context, the browser and the drag");
  const size_t before_drag = t.sent.size();
  cmux_shim_set_drag_source_handler(Drag, &other);
  Check(t.sent.size() == before_drag, "replacing the drag handler sends nothing");
  cmux_shim_set_drag_source_handler(nullptr, nullptr);
  Check(Last(t) == "drag off", "removing the drag handler is sent");
  Check(!cmux_remote::DeliverDragStart(2, &drag), "no drag handler, no call");

  // Password reveal: a token on the wire, done exactly once with the REPLY bytes.
  Check(cmux_shim_password_reveal("", "id1", Reveal, &ctx) == 0, "reveal refuses an empty path");
  Check(cmux_shim_password_reveal("/profile", nullptr, Reveal, &ctx) == 0, "reveal refuses a missing id");
  Check(cmux_shim_password_reveal("/profile", "id1", nullptr, &ctx) == 0, "reveal refuses a missing done");
  Check(cmux_shim_password_reveal("/profile", "id1", Reveal, &ctx) == 1, "reveal starts");
  const uint32_t token = t.token;
  Check(Last(t) == "reveal " + std::to_string(token) + " /profile id1", "reveal sends its token");
  Check(!cmux_remote::DeliverPasswordReveal(token + 1, "nope", 4), "an unknown token is refused");
  Check(cmux_remote::DeliverPasswordReveal(token, "s3cretXX", 6), "the REPLY reaches done");
  Check(reveal_seen.calls == 1 && reveal_seen.ctx == &ctx && reveal_seen.bytes == "s3cret",
        "done gets its context and the bytes");
  Check(!cmux_remote::DeliverPasswordReveal(token, "s3cret", 6), "done runs once");
  Check(cmux_shim_password_reveal("/profile", "id2", Reveal, &other) == 1, "second reveal starts");
  Check(cmux_remote::DeliverPasswordReveal(t.token, nullptr, 5), "a not-found REPLY reaches done");
  Check(reveal_seen.calls == 2 && reveal_seen.null_password && reveal_seen.bytes.empty(),
        "not found is done(NULL, 0)");
  t.accept = false;
  Check(cmux_shim_password_reveal("/profile", "id3", Reveal, &ctx) == 0, "a reveal the transport refused returns 0");
  t.accept = true;
  Check(!cmux_remote::DeliverPasswordReveal(t.token, "x", 1), "a refused reveal is not pending");

  // Host gone: pending reveals end, watches end, the next host initializes again.
  cmux_shim_set_drag_source_handler(Drag, &ctx);
  Check(cmux_shim_browser_text_input_watch(11, WatchA, &ctx) == 1, "watch before detach");
  Check(cmux_shim_password_reveal("/profile", "id4", Reveal, &other) == 1, "reveal before detach");
  const uint32_t pending = t.token;
  cmux_remote::Detach();
  Check(reveal_seen.calls == 3 && reveal_seen.null_password && reveal_seen.ctx == &other,
        "detach ends a pending reveal with done(NULL, 0)");
  Check(!cmux_remote::DeliverPasswordReveal(pending, "late", 4), "a late REPLY after detach is refused");
  Check(!cmux_remote::DeliverTextInputState(11, &state), "detach ends the watches");
  Check(InitializeShim(&ctx) == 0, "initialize with no host returns 0");
  t.sent.clear();
  cmux_remote::Attach(&transport);
  Check(Last(t) == "drag on", "re-attach sends the drag handler again");
  Check(InitializeShim(&ctx) == 1, "the next host initializes");

  if (failures == 0) std::printf("remote_shim_local_test: ok\n");
  return failures == 0 ? 0 : 1;
}
