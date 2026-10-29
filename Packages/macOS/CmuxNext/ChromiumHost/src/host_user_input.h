// Input on Chromium's UI thread the way Chrome runs it
// (plans/cmux-next/chrome-parity/p04-input.md (H)): on the user-input queue,
// with the OS event's time. Needs no CEF: tests/host_user_input_test.cpp
// (scripts/cmux-next/tests/chromium-host-wire.test.sh) compiles it alone.
//
// Queue. Chrome posts OS input to the UI thread's user-input queue
// (BrowserTaskType::kUserInput, content/public/browser/browser_task_traits.h),
// which BrowserUIThreadScheduler runs before the other UI queues, so a key
// does not wait behind queued UI work. The fork's cmux_post_user_input_task
// (API 30) posts there; with a fork without it the host uses
// CefPostTask(TID_UI), the default queue. InputTasks chooses the queue once,
// at start, and is the host's one input path: HostInput's Post
// (chromium_host_input_ring.h, started by task p01-process-042) is
// `[&input_tasks](std::function<void()> task) { input_tasks.Post(std::move(task)); }`.
// Both queues refuse a task only once Chromium's UI thread is shut down. A
// refused task is dropped, not posted again to the other queue: its batch
// never runs, so HostInput's BatchGate stays shut, the reader takes no more
// frames (they stay in the ring) and HostInput::Stop ends it.
//
// Time. A frame's t0 is its NSEvent's timestamp (EventTimeOf in
// chromium_host_wire.h). CEF's Send*Event calls stamp an event with the time
// they are called. The fork's cmux_set_input_event_time (a PL-cef-layer fork
// item after API 31) gives the events that follow the OS time instead:
//   int cmux_set_input_event_time(int64_t event_time_ns);
// Until the next call, the input events the embedder sends on the UI thread
// (CefBrowserHost::Send*Event, cmux_browser_send_wheel and the Ime* calls)
// have `event_time_ns` (CLOCK_UPTIME_RAW nanoseconds, the clock of
// base::TimeTicks on macOS) as their time; 0 gives them the time they are
// sent again. Returns 1. UI thread only. ScopedEventTime holds a time for one
// frame's dispatch.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <utility>

namespace cmux_host {

// The fork's cmux_post_user_input_task: 1 when `fn(context)` will run on the
// UI thread, 0 when it will not.
using PostTaskFn = int (*)(void (*fn)(void* context), void* context);
// The fork's cmux_set_input_event_time.
using SetEventTimeFn = int (*)(int64_t event_time_ns);

// Posts `task` through a C task call: true when posted; false when refused,
// and then `task` is destroyed here and does not run. Any thread.
inline bool PostThrough(PostTaskFn post, std::function<void()> task) {
  auto* boxed = new std::function<void()>(std::move(task));
  const int posted = post(
      [](void* context) {
        std::unique_ptr<std::function<void()>> run(static_cast<std::function<void()>*>(context));
        (*run)();
      },
      boxed);
  if (posted) return true;
  delete boxed;
  return false;
}

// The queue that runs input frames on the UI thread, chosen once at start.
class InputTasks {
 public:
  using Task = std::function<void()>;
  // Posts a task to one UI thread queue. A queue that refuses it (its thread
  // is shut down) frees it unrun.
  using Queue = std::function<void(Task)>;
  enum class Chosen { kUserInput, kDefault };

  // `user_input`: the fork's user-input queue, empty when the fork does not
  // have it. `default_queue`: CefPostTask(TID_UI). `before_start`: the main
  // run loop, where tasks run in post order before Chromium's UI thread
  // exists (PostToMain).
  InputTasks(Queue user_input, Queue default_queue, Queue before_start)
      : chosen_(user_input ? Chosen::kUserInput : Chosen::kDefault),
        queue_(user_input ? std::move(user_input) : std::move(default_queue)),
        before_start_(std::move(before_start)) {}
  InputTasks(const InputTasks&) = delete;
  InputTasks& operator=(const InputTasks&) = delete;

  Chosen chosen() const { return chosen_; }

  // The UI thread, once CefInitialize returned: later posts go to the chosen
  // queue.
  void Start() { started_.store(true, std::memory_order_release); }

  // Any thread; HostInput's Post. Before Start, on the main run loop; after
  // it, on the chosen queue, or dropped unrun when that queue refuses it
  // (Chromium's UI thread is shut down). Tasks keep their order across Start
  // only for a caller with one task in flight (input_ring::BatchGate).
  void Post(Task task) const {
    if (!started_.load(std::memory_order_acquire)) {
      before_start_(std::move(task));
      return;
    }
    queue_(std::move(task));
  }

 private:
  const Chosen chosen_;
  const Queue queue_;
  const Queue before_start_;
  std::atomic<bool> started_{false};
};

// Gives the events sent to Chromium in its scope the time `event_time_ns`
// (EventTimeOf), then the send time again. Nothing with no fork call (`set`
// nullptr) or no event time (0). UI thread.
class ScopedEventTime {
 public:
  ScopedEventTime(SetEventTimeFn set, uint64_t event_time_ns) : set_(event_time_ns != 0 ? set : nullptr) {
    if (set_) set_(static_cast<int64_t>(event_time_ns));
  }
  ~ScopedEventTime() {
    if (set_) set_(0);
  }
  ScopedEventTime(const ScopedEventTime&) = delete;
  ScopedEventTime& operator=(const ScopedEventTime&) = delete;

 private:
  const SetEventTimeFn set_;
};

}  // namespace cmux_host
