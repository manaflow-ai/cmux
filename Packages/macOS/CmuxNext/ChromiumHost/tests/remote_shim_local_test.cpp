// Checks the remote shim's local class (client/remote_shim_local.mm) against a
// fake transport: callbacks stay in the client, the host's pushes reach them,
// and nothing waits (scripts/cmux-next/tests/remote-shim-local.test.sh).
#include <csignal>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <sys/wait.h>
#include <unistd.h>

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
};

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

// True when a text input push delivered on another thread aborts (the main
// thread assert), in a child process so the abort ends only the child.
bool OffMainDeliveryAborts() {
  const pid_t child = fork();
  if (child == 0) {
    if (std::freopen("/dev/null", "w", stderr) == nullptr) _exit(2);  // hides the expected assert message
    int state = 0;
    std::thread([&] { cmux_remote::DeliverTextInputState(7, &state); }).join();
    _exit(0);
  }
  int status = 0;
  return child > 0 && waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
}

}  // namespace

int main() {
  FakeTransport t;
  const cmux_remote::LocalTransport transport{&t, SendTextInputWatch, SendDragSourceHandler, SendPasswordReveal,
                                              NextToken};
  int ctx = 0, other = 0;

  // Before the host attaches nothing is sent and nothing pretends to start.
  Check(cmux_shim_browser_text_input_watch(7, WatchA, &ctx) == 0, "watch before attach returns 0");
  Check(cmux_shim_password_reveal("/profile", "id1", Reveal, &ctx) == 0, "reveal before attach returns 0");
  cmux_shim_set_drag_source_handler(Drag, &ctx);
  Check(t.sent.empty(), "nothing sent before attach");

  // post_user_input_task never runs fn in the client: the host has its own queue.
  Check(cmux_shim_post_user_input_task(UserInput, &ctx) == 0, "post_user_input_task returns 0");
  Check(user_input_calls == 0, "post_user_input_task never runs fn");

  // Attach sends the drag handler set before it.
  cmux_remote::Attach(&transport);
  Check(Last(t) == "drag on", "attach sends the earlier drag handler");

  // Text input: the watch on/off crosses the wire once; the callback stays here.
  const size_t before_watch = t.sent.size();
  Check(cmux_shim_browser_text_input_watch(7, WatchA, &ctx) == 1, "watch starts");
  Check(Last(t) == "watch 7 on", "watch start is sent");
  Check(cmux_shim_browser_text_input_watch(7, WatchB, &other) == 1, "watch replaced");
  Check(t.sent.size() == before_watch + 1, "replacing a watch sends nothing");
  int state = 0;
  Check(cmux_remote::DeliverTextInputState(7, &state), "TEXT_INPUT_STATE reaches the watch");
  // During the transport's batch call, once: nothing is deferred past it.
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

  // A refused drag send is not taken as sent: the next set sends it.
  t.accept = false;
  cmux_shim_set_drag_source_handler(Drag, &ctx);
  t.accept = true;
  Check(Last(t) == "drag off", "a refused drag install sends nothing");
  cmux_shim_set_drag_source_handler(Drag, &ctx);
  Check(Last(t) == "drag on", "the next set sends the install the transport refused");
  t.accept = false;
  cmux_shim_set_drag_source_handler(nullptr, nullptr);
  t.accept = true;
  cmux_shim_set_drag_source_handler(nullptr, nullptr);
  Check(Last(t) == "drag off", "the next set sends the removal the transport refused");

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

  // Host gone: pending reveals end, watches end.
  cmux_shim_set_drag_source_handler(Drag, &ctx);
  Check(cmux_shim_browser_text_input_watch(11, WatchA, &ctx) == 1, "watch before detach");
  Check(cmux_shim_password_reveal("/profile", "id4", Reveal, &other) == 1, "reveal before detach");
  const uint32_t pending = t.token;
  cmux_remote::Detach();
  Check(reveal_seen.calls == 3 && reveal_seen.null_password && reveal_seen.ctx == &other,
        "detach ends a pending reveal with done(NULL, 0)");
  Check(!cmux_remote::DeliverPasswordReveal(pending, "late", 4), "a late REPLY after detach is refused");
  Check(!cmux_remote::DeliverTextInputState(11, &state), "detach ends the watches");
  t.sent.clear();
  cmux_remote::Attach(&transport);
  Check(Last(t) == "drag on", "re-attach sends the drag handler again");

  // An attach whose drag send is refused sends it at the next set.
  cmux_remote::Detach();
  t.sent.clear();
  t.accept = false;
  cmux_remote::Attach(&transport);
  t.accept = true;
  Check(t.sent.empty(), "a refused attach drag send sends nothing");
  cmux_shim_set_drag_source_handler(Drag, &ctx);
  Check(Last(t) == "drag on", "the next set after a refused attach sends the handler");

#if !defined(NDEBUG)
  // Callbacks run on main: a push delivered on another thread is refused.
  Check(cmux_shim_browser_text_input_watch(7, WatchA, &ctx) == 1, "watch for the off-main check");
  Check(OffMainDeliveryAborts(), "a push delivered off main aborts");
#endif

  if (failures == 0) std::printf("remote_shim_local_test: ok\n");
  return failures == 0 ? 0 : 1;
}
