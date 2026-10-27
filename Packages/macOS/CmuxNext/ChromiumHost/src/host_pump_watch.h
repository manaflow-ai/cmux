// The Chromium Host's message loop, watched (plans/cmux-next/chrome-parity/
// p09-observability.md, task 104 (b) and (e)). The host runs Chromium's own
// loop (CefRunMessageLoop, base's MessagePumpNSApplication over the main run
// loop), so a CFRunLoop observer in browser_host_main.mm cuts it into work
// items: from the run loop waking (or starting its timers or sources) to its
// next wait, each item is one pass of the pump. For each item:
//   - a hang scope: an item still open kHangAfterNs after it began is a hang,
//     reported once (a hang.thread_hung record, the hang_in_progress_start
//     crash key, a line on stderr) without ending the host, as Chrome's
//     HangWatcher watches each task of a watched thread (base/threading/
//     hang_watcher.h, WatchHangsInScope in base/task/common/task_annotator.cc)
//     and dumps without crashing;
//   - the in_cef_pump crash key, so a crash inside a pass says so;
//   - cef.pump (B/E, only while the cef and task categories record) and the
//     pass's time in the host's metrics file (host_pump_metrics.h).
//
// The watcher thread parks with no timer while no item is open (the loop
// waits), sleeps to the open item's deadline otherwise, and an opener wakes it
// only when it is parked: an idle host has no watcher wakeup, a busy one at
// most one per kHangAfterNs (Chrome's watcher instead wakes every 10 s).
//
// Header-only, no CEF; tests/host_pump_watch_test.cpp builds it on Linux.
#pragma once

#include <pthread.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <mutex>
#include <thread>

#include "host_black_box.h"
#include "host_pump_metrics.h"

namespace cmux_host {

// A pass of the host's loop open this long is a hang (the app's HangWatch
// hang tier: its budget plus hangAfterBudget).
inline constexpr uint64_t kHangAfterNs = 2'000'000'000;

// One watched thread's open scope and the thread that watches it. Open and
// Close are the watched thread's (two stores, and a lock only to wake a parked
// watcher); the watcher reports through `report` on its own thread.
class HangScopeWatch {
 public:
  // `report(began_ns, overrun_ns)`: the open scope began at `began_ns` and is
  // `overrun_ns` past its deadline now.
  using Report = std::function<void(uint64_t began_ns, uint64_t overrun_ns)>;
  using Now = uint64_t (*)();

  HangScopeWatch(uint64_t after_ns, Report report, Now now) : after_ns_(after_ns), report_(std::move(report)), now_(now) {}
  HangScopeWatch(const HangScopeWatch&) = delete;
  HangScopeWatch& operator=(const HangScopeWatch&) = delete;
  ~HangScopeWatch() { Stop(); }

  // Starts the watcher thread (once).
  void Start(const char* name) {
    if (thread_.joinable()) return;
    thread_ = std::thread([this, name] {
#if defined(__APPLE__)
      pthread_setname_np(name);
      pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#else
      (void)name;
#endif
      Watch();
    });
  }

  // Ends the watcher thread and waits for it.
  void Stop() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
    }
    wake_.notify_one();
    if (thread_.joinable()) thread_.join();
  }

  // The watched thread opens a scope at `now_ns`. A scope still open is closed first.
  void Open(uint64_t now_ns) {
    began_.store(now_ns, std::memory_order_relaxed);
    deadline_.store(now_ns + after_ns_, std::memory_order_seq_cst);
    if (parked_.load(std::memory_order_seq_cst)) {
      std::lock_guard<std::mutex> lock(mutex_);
      wake_.notify_one();
    }
  }

  // The watched thread closes its scope. True when the scope was reported as a hang.
  bool Close() {
    const uint64_t deadline = deadline_.exchange(0, std::memory_order_seq_cst);
    return deadline != 0 && reported_.load(std::memory_order_acquire) == deadline;
  }

  // Hangs reported since start.
  uint64_t hangs() const { return hangs_.load(std::memory_order_relaxed); }
  // Times the watcher woke (a deadline or a wake).
  uint64_t wakes() const { return wakes_.load(std::memory_order_relaxed); }
  // The watcher waits with no deadline.
  bool parked() const { return parked_.load(std::memory_order_seq_cst); }

 private:
  void Watch() {
    std::unique_lock<std::mutex> lock(mutex_);
    // wakeup-allow: bounded each pass waits for an open scope (untimed) or its one deadline; it ends at Stop
    while (!stopping_) {
      const uint64_t deadline = deadline_.load(std::memory_order_seq_cst);
      if (deadline == 0 || reported_.load(std::memory_order_relaxed) == deadline) {
        // Nothing open, or the open scope is reported: park until a scope opens.
        parked_.store(true, std::memory_order_seq_cst);
        wake_.wait(lock, [&] { return stopping_ || Changed(deadline); });
        parked_.store(false, std::memory_order_seq_cst);
        wakes_.fetch_add(1, std::memory_order_relaxed);
        continue;
      }
      const uint64_t now = now_();
      if (now < deadline) {
        // wakeup-allow: deadline the open scope's one deadline; a new scope moves it
        wake_.wait_for(lock, std::chrono::nanoseconds(deadline - now), [&] { return stopping_ || Changed(deadline); });
        wakes_.fetch_add(1, std::memory_order_relaxed);
        continue;
      }
      // The same scope, still open past its deadline: report it once.
      reported_.store(deadline, std::memory_order_release);
      hangs_.fetch_add(1, std::memory_order_relaxed);
      const uint64_t began = began_.load(std::memory_order_relaxed);
      lock.unlock();
      report_(began, now - deadline);
      lock.lock();
    }
  }

  bool Changed(uint64_t seen) const { return deadline_.load(std::memory_order_seq_cst) != seen; }

  const uint64_t after_ns_;
  const Report report_;
  const Now now_;
  std::atomic<uint64_t> deadline_{0};  // the open scope's deadline, 0 with none
  std::atomic<uint64_t> began_{0};
  std::atomic<uint64_t> reported_{0};  // the deadline of the last scope reported
  std::atomic<bool> parked_{false};
  std::atomic<uint64_t> hangs_{0};
  std::atomic<uint64_t> wakes_{0};
  std::mutex mutex_;  // the watcher's park and wait, and Stop
  std::condition_variable wake_;
  bool stopping_ = false;
  std::thread thread_;
};

// The work items of the host's main run loop. Main thread only (the observer).
class PumpWatch {
 public:
  PumpWatch(HostBlackBox& black_box, PumpMetrics& metrics, HangScopeWatch::Now now)
      : black_box_(black_box),
        metrics_(metrics),
        now_(now),
        hangs_(
            kHangAfterNs,
            [&black_box](uint64_t began_ns, uint64_t overrun_ns) {
              black_box.SetKey(CMUX_CRASH_KEY_HANG_IN_PROGRESS_START, began_ns);
              black_box.Point(CMUX_TRACE_CAT_HANG, kTraceHangThreadHung, CMUX_TRACE_PHASE_INSTANT, 0,
                              overrun_ns / 1'000'000);
              fprintf(stderr, "cmux-chromium-host: the main thread is %llu ms past its hang deadline\n",
                      static_cast<unsigned long long>(overrun_ns / 1'000'000));
            },
            now) {}

  void Start() { hangs_.Start("com.cmuxterm.chromium-host.hang-watch"); }
  void Stop() { hangs_.Stop(); }

  // The loop starts an item (it woke, or runs its timers or sources): the
  // item before it, if any, ends here.
  void Begin() {
    const uint64_t now = now_();
    if (open_) End(now);
    open_ = true;
    began_ = now;
    hangs_.Open(now);
    black_box_.SetKey(CMUX_CRASH_KEY_IN_CEF_PUMP, 1);
    traced_ = black_box_.Enabled(CMUX_TRACE_CAT_CEF) && black_box_.Enabled(CMUX_TRACE_CAT_TASK);
    if (traced_) black_box_.Point(CMUX_TRACE_CAT_CEF, kTraceCefPump, CMUX_TRACE_PHASE_BEGIN, 0);
  }

  // The loop is about to wait (or leaves): the open item ends.
  void Wait() {
    if (open_) End(now_());
  }

  const HangScopeWatch& hangs() const { return hangs_; }
  uint64_t items() const { return items_; }

 private:
  void End(uint64_t now) {
    open_ = false;
    const uint64_t micros = (now - began_) / 1000;
    if (hangs_.Close()) black_box_.SetKey(CMUX_CRASH_KEY_HANG_IN_PROGRESS_START, 0);
    black_box_.SetKey(CMUX_CRASH_KEY_IN_CEF_PUMP, 0);
    // The E of a B written, whatever the categories are now (the app's endRecorded).
    if (traced_) black_box_.Point(CMUX_TRACE_CAT_ALL, kTraceCefPump, CMUX_TRACE_PHASE_END, 0, micros);
    metrics_.Record(micros);
    ++items_;
  }

  HostBlackBox& black_box_;
  PumpMetrics& metrics_;
  const HangScopeWatch::Now now_;
  HangScopeWatch hangs_;
  bool open_ = false;
  bool traced_ = false;
  uint64_t began_ = 0;
  uint64_t items_ = 0;
};

}  // namespace cmux_host
