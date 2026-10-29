// Checks the host's input queue choice and event time scope
// (ChromiumHost/src/host_user_input.h;
// scripts/cmux-next/tests/chromium-host-wire.test.sh).
#include <cstdio>
#include <functional>
#include <memory>
#include <utility>
#include <vector>

#include "../src/host_user_input.h"

static int failures = 0;

static void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

namespace {

using cmux_host::InputTasks;

// A fake C task queue (the fork's cmux_post_user_input_task): it holds what it
// takes and runs it on Drain, or refuses while `refuse` is set.
struct FakeForkQueue {
  static inline std::vector<std::pair<void (*)(void*), void*>> held;
  static inline bool refuse = false;
  static inline int calls = 0;
  static int Post(void (*fn)(void*), void* context) {
    ++calls;
    if (refuse) return 0;
    held.emplace_back(fn, context);
    return 1;
  }
  static void Drain() {
    auto tasks = std::move(held);
    held.clear();
    for (auto& [fn, context] : tasks) fn(context);
  }
};

// Records which queue took each task and runs nothing until asked; while
// `refuse` is set the UI thread queues refuse (and so free) what they get.
struct Queues {
  std::vector<InputTasks::Task> user_input, fallback, main;
  bool refuse = false;
  int refused = 0;
  InputTasks::Queue UserInput() { return Into(&user_input); }
  InputTasks::Queue Fallback() { return Into(&fallback); }
  InputTasks::Queue Main() {
    return [this](InputTasks::Task task) { main.push_back(std::move(task)); };
  }

 private:
  InputTasks::Queue Into(std::vector<InputTasks::Task>* queue) {
    return [this, queue](InputTasks::Task task) {
      if (refuse) {
        ++refused;
        return;
      }
      queue->push_back(std::move(task));
    };
  }
};

std::vector<int64_t> g_times;
int SetTime(int64_t event_time_ns) {
  g_times.push_back(event_time_ns);
  return 1;
}

}  // namespace

static void TestQueueChoice() {
  {
    Queues q;
    InputTasks tasks(q.UserInput(), q.Fallback(), q.Main());
    Check(tasks.chosen() == InputTasks::Chosen::kUserInput, "a fork with the call gets the user-input queue");
    tasks.Post([] {});
    Check(q.main.size() == 1 && q.user_input.empty(),
          "before Chromium's UI thread exists a task goes to the main run loop");
    tasks.Start();
    for (int i = 0; i < 3; ++i) tasks.Post([] {});
    Check(q.user_input.size() == 3 && q.fallback.empty() && q.main.size() == 1,
          "after start every task goes to the user-input queue");
    q.refuse = true;
    int ran = 0;
    auto alive = std::make_shared<int>(0);
    tasks.Post([&ran, alive] { ++ran; });
    Check(q.refused == 1 && ran == 0 && alive.use_count() == 1, "a refused task is dropped unrun and freed");
    Check(q.user_input.size() == 3 && q.fallback.empty() && q.main.size() == 1,
          "a refused task is not posted again to another queue: the choice is made once, not per task");
  }
  {
    Queues q;
    InputTasks tasks(InputTasks::Queue(), q.Fallback(), q.Main());
    Check(tasks.chosen() == InputTasks::Chosen::kDefault, "a fork without the call gets CefPostTask(TID_UI)");
    tasks.Start();
    tasks.Post([] {});
    tasks.Post([] {});
    Check(q.fallback.size() == 2 && q.user_input.empty(), "every task goes to the default queue");
  }
}

static void TestPostThrough() {
  FakeForkQueue::held.clear();
  FakeForkQueue::refuse = false;
  int ran = 0;
  auto alive = std::make_shared<int>(0);
  Check(cmux_host::PostThrough(&FakeForkQueue::Post, [&ran, alive] { ++ran; }), "a posted task reports it");
  Check(ran == 0 && alive.use_count() == 2, "the task waits in the queue");
  FakeForkQueue::Drain();
  Check(ran == 1 && alive.use_count() == 1, "it runs once and is freed after it ran");
  FakeForkQueue::refuse = true;
  Check(!cmux_host::PostThrough(&FakeForkQueue::Post, [&ran, alive] { ++ran; }), "a refused task reports it");
  Check(ran == 1 && alive.use_count() == 1, "a refused task never runs and is freed at once");
}

static void TestEventTimeScope() {
  g_times.clear();
  {
    cmux_host::ScopedEventTime scope(&SetTime, 1234);
    Check(g_times.size() == 1 && g_times[0] == 1234, "the fork gets the frame's event time before the send");
  }
  Check(g_times.size() == 2 && g_times[1] == 0, "and the send time again after it");
  g_times.clear();
  { cmux_host::ScopedEventTime scope(&SetTime, 0); }
  Check(g_times.empty(), "a frame with no event time leaves the fork's time alone");
  { cmux_host::ScopedEventTime scope(nullptr, 1234); }
  Check(g_times.empty(), "a fork without the call is not called");
}

int main() {
  TestQueueChoice();
  TestPostThrough();
  TestEventTimeScope();
  if (failures) return 1;
  std::printf("host_user_input_test: ok\n");
  return 0;
}
