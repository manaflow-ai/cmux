// Checks the host's page state pushes (src/host_page_state.h, task
// p01-process-093) alone: a burst of the fork's reports is one push per
// entry at the idle task, in report order; one idle task per burst; reports
// of an unwatched browser or an index past Chromium's entry limit are
// dropped; a forgotten browser's waiting entries go with it; the idle task
// of a destroyed object does nothing. Built and run by
// scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "host_page_state.h"

namespace {

using cmux_host::PageStatePushes;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

struct Pushed {
  int browser;
  int32_t index;
  bool operator==(const Pushed&) const = default;
};

struct Harness {
  std::vector<Pushed> pushed;
  std::vector<std::function<void()>> idle;
  std::unique_ptr<PageStatePushes> pushes;

  explicit Harness(bool waits = true) {
    pushes = std::make_unique<PageStatePushes>([this](int browser, int32_t index) { pushed.push_back({browser, index}); });
    if (waits) pushes->SetRequestIdle([this](std::function<void()> task) { idle.push_back(std::move(task)); });
  }

  void RunIdle() {
    std::vector<std::function<void()>> tasks;
    tasks.swap(idle);
    for (auto& task : tasks) task();
  }
};

void ABurstIsOnePushPerEntryAtIdle() {
  Harness h;
  h.pushes->Watch(7);
  // The renderer's scroll updates and a form edit of entry 2, then a commit of entry 3.
  for (int i = 0; i < 5; ++i) h.pushes->Reported(7, 2);
  h.pushes->Reported(7, 3);
  h.pushes->Reported(7, 2);
  Check(h.pushed.empty(), "nothing goes out before idle");
  Check(h.idle.size() == 1, "one idle task for the burst");
  Check(h.pushes->waiting() == 2, "each entry waits once");
  h.RunIdle();
  Check((h.pushed == std::vector<Pushed>{{7, 2}, {7, 3}}), "each entry once, in report order");
  Check(h.pushes->stats().reports == 7 && h.pushes->stats().pushes == 2 && h.pushes->stats().idles == 1,
        "the counters say 7 reports, 2 pushes, 1 idle");
  h.pushes->Reported(7, 2);
  Check(h.idle.size() == 1, "a report after the flush starts a new idle task");
  h.RunIdle();
  Check(h.pushed.size() == 3, "and pushes again");
}

void OnlyWatchedBrowsersAndRealEntries() {
  Harness h;
  h.pushes->Reported(9, 0);
  Check(h.idle.empty() && h.pushes->waiting() == 0, "an unwatched browser's report is dropped");
  h.pushes->Watch(9);
  h.pushes->Reported(9, -1);
  h.pushes->Reported(9, cmux_host::kMaxPageStateEntries);
  Check(h.pushes->waiting() == 0, "an index outside Chromium's 50 entries is dropped");
  h.pushes->Reported(9, cmux_host::kMaxPageStateEntries - 1);
  Check(h.pushes->waiting() == 1, "the last entry is kept");
}

void AForgottenBrowserTakesItsEntries() {
  Harness h;
  h.pushes->Watch(1);
  h.pushes->Watch(2);
  h.pushes->Reported(1, 0);
  h.pushes->Reported(2, 0);
  h.pushes->Reported(1, 1);
  h.pushes->Forget(1);  // the tab closed, or cmux stopped watching
  Check(!h.pushes->watching(1) && h.pushes->watches() == 1, "the browser is no longer watched");
  h.RunIdle();
  Check((h.pushed == std::vector<Pushed>{{2, 0}}), "only the watched browser's entry goes out");
}

void APushThatForgetsSkipsTheRest() {
  Harness h;
  // As a push whose event closes the tab in its turn.
  h.pushes = std::make_unique<PageStatePushes>([&h](int browser, int32_t index) {
    h.pushed.push_back({browser, index});
    h.pushes->Forget(browser);
  });
  h.pushes->SetRequestIdle([&h](std::function<void()> task) { h.idle.push_back(std::move(task)); });
  h.pushes->Watch(4);
  h.pushes->Reported(4, 0);
  h.pushes->Reported(4, 1);
  h.RunIdle();
  Check((h.pushed == std::vector<Pushed>{{4, 0}}), "the entry after a push that forgot the browser is skipped");
  h.pushes->Reported(4, 1);
  Check(h.idle.empty() && h.pushed.size() == 1, "a forgotten browser sends nothing");
}

void NoIdleSendsAtOnce() {
  Harness h(false);
  h.pushes->Watch(3);
  h.pushes->Reported(3, 5);
  Check((h.pushed == std::vector<Pushed>{{3, 5}}), "with no idle task the report goes out at once");
}

void AnIdleTaskOutlivingThePushesDoesNothing() {
  Harness h;
  h.pushes->Watch(3);
  h.pushes->Reported(3, 0);
  h.pushes.reset();
  h.RunIdle();
  Check(h.pushed.empty(), "the idle task of destroyed pushes sends nothing");
}

}  // namespace

int main() {
  ABurstIsOnePushPerEntryAtIdle();
  OnlyWatchedBrowsersAndRealEntries();
  AForgottenBrowserTakesItsEntries();
  APushThatForgetsSkipsTheRest();
  NoIdleSendsAtOnce();
  AnIdleTaskOutlivingThePushesDoesNothing();
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host-page-state tests: ok");
  return EXIT_SUCCESS;
}
