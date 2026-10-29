// The Chromium Host's hang watch on its main run loop (host_hang_watcher.h):
// run loop observers open and close each turn of the
// UI thread, the clock is CLOCK_UPTIME_RAW (base::TimeTicks on macOS, which
// stops while the Mac sleeps, so a sleep is never a hang), and a turn still
// open after kDumpNs gets CEF's DumpWithoutCrashing, as Chrome's HangWatcher
// calls base::debug::DumpWithoutCrashing (base/threading/hang_watcher.cc,
// RecordHang) from its watcher thread.

#include "host_hang_watcher.h"

#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <time.h>

#include <climits>
#include <cstdio>

#if __has_include("include/base/cef_dump_without_crashing.h")
#include "include/base/cef_dump_without_crashing.h"
#define CMUX_HOST_HAS_CEF_DUMP 1
#else
#define CMUX_HOST_HAS_CEF_DUMP 0
#endif

namespace cmux_host::hang {
namespace {

uint64_t UptimeNs() {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// False when crash reporting is off (no crash_reporter.cfg),
// when throttled, or when the CEF build has no dump call.
bool DumpHang() {
#if CMUX_HOST_HAS_CEF_DUMP
  // At most one hang dump an hour: CEF throttles by call site, as
  // base::debug::DumpWithoutCrashing does, so a host stuck in a loop of long
  // turns does not fill the crash directory.
  constexpr long long kDumpThrottleMs = 60LL * 60 * 1000;
  return CefDumpWithoutCrashing(kDumpThrottleMs);
#else
  return false;
#endif
}

// The watcher sleeps, wakes at a deadline at most once per long turn and
// writes a dump; utility QoS is enough and keeps it off the input cores.
void BecomeWatcherThread() {
  pthread_setname_np(kWatcherLabel);
  pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
}

// A turn begins when the run loop wakes up and before each pass over its
// sources (Chromium's work source is a source0: MessagePumpCFRunLoopBase in
// base/message_loop/message_pump_apple.mm runs its tasks there). First of the
// observers of those activities, so Chromium's own run inside the turn.
constexpr CFOptionFlags kBeginActivities = kCFRunLoopAfterWaiting | kCFRunLoopBeforeSources;
// A turn ends when the run loop is about to wait or leaves. Last of the
// observers, so Chromium's pre-wait work (its idle work) is inside the turn.
constexpr CFOptionFlags kEndActivities = kCFRunLoopBeforeWaiting | kCFRunLoopExit;

CFRunLoopObserverRef AddObserver(CFOptionFlags activities, CFIndex order, Watch* watch, bool begins) {
  CFRunLoopObserverRef observer =
      CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, order, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
        if (begins) {
          watch->BeginTurn();
        } else {
          watch->EndTurn();
        }
      });
  CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
  return observer;
}

void RemoveObserver(void*& observer) {
  if (observer == nullptr) return;
  auto ref = static_cast<CFRunLoopObserverRef>(observer);
  CFRunLoopObserverInvalidate(ref);
  CFRelease(ref);
  observer = nullptr;
}

}  // namespace

HostHangWatch::HostHangWatch(Watch::Send send)
    : watch_(&UptimeNs, std::move(send), &DumpHang, Limits(), &BecomeWatcherThread) {
  begin_observer_ = AddObserver(kBeginActivities, LONG_MIN, &watch_, true);
  end_observer_ = AddObserver(kEndActivities, LONG_MAX, &watch_, false);
  // With no watcher (no wake pipe) turns still report and ack on the UI thread; only the 10 s dump goes.
  if (!watch_.Start()) fprintf(stderr, "cmux-chromium-host: no hang watcher: no 10 s hang dumps\n");
}

HostHangWatch::~HostHangWatch() {
  Stop();
}

void HostHangWatch::Stop() {
  RemoveObserver(begin_observer_);
  RemoveObserver(end_observer_);
  watch_.Stop();
}

}  // namespace cmux_host::hang
