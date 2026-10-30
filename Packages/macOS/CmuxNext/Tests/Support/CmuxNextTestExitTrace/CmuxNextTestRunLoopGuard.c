// A stray stop of the main run loop ended the whole test run, quietly.
//
// `swift_task_asyncMainDrainQueue` runs the main run loop and calls `exit(0)` the moment that run
// returns, so `main` never comes back to the test runner: the tests still in flight never report,
// and swift-testing never prints its summary line. Anything that calls `CFRunLoopStop` while the
// outermost run is the current one does this, whether it is a test that means to end its own
// nested pass and is a turn late, or AppKit waking an event wait
// (`-[NSEvent _postAtStart:]` calls `CFRunLoopStop`). Run 40317841968 is the shape: that exit
// stack, 2793 tests started and never finished, and before the reporting gate in
// scripts/cmux-next/swift-test-with-hang-sampler.sh the job still read as a pass.
//
// So the drain queue's own run is never the innermost one. A block posted to the main run loop
// before any test starts runs a NESTED run, and restarts it whenever it returns. A stray
// `CFRunLoopStop` then ends that nested run, which this loop immediately replaces, instead of the
// run whose return exits the process.
//
// The first shape of this fix re-entered from inside a `kCFRunLoopExit` observer, and run
// 40321954380 showed why that is not enough: it re-entered exactly once (885 tests still lost
// instead of 2793), because the run it started from inside the callout could not get the observer
// to fire again for its own exit. A plain `while` loop in a block has no such problem, and does
// not grow the stack by a frame per stop either.
//
// A finished run cannot be kept alive by accident: swift-testing calls `exit()` itself from its
// own job on a dispatch worker thread (its stack is in the same logs), which ends the process at
// any run depth. `CMUX_NEXT_TEST_RUNLOOP_GUARD=0` turns the guard off, which is how its regression
// test is proven red on the same binary.
#include "CmuxNextTestExitTrace.h"

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int guard_installed;
/// Whether the block below is holding a run open. 0 when CMUX_NEXT_TEST_RUNLOOP_GUARD=0 turned the
/// guard off: the depth counting and the probe still work, so the regression test can take the
/// same stop on an unprotected process and really die of it.
static int guard_holding;
/// Runs of the main run loop in the common modes, outermost first. A nested pass in a private mode
/// is not counted, and must not be: stopping one of those ends that pass, not the outermost run.
static int run_depth;
/// How many times the nested run has been restarted after returning.
static int restarts;
/// A stop every turn would otherwise spin this loop as fast as the CPU allows. After this many
/// restarts the guard stands aside and the process ends the way it would have without it; the
/// reporting gate turns the short run into a red job.
static const int restart_cap = 100000;
/// Restarts that returned at once (under this many microseconds) in a row. A run that cannot block
/// -- an empty mode, a loop left in its stopped state -- would spin; after `spin_cap` of them in a
/// row the guard stands aside rather than burn a core.
static int spins;
static const int spin_cap = 1000;
static const long long spin_microseconds = 1000;

/// The test probe below: a timer that stops the run the guard protects, the way a real stray stop
/// reaches it. It fires only when THAT run is the current one (`guard_floor()` deep), because a
/// stop taken while a sibling test's nested pass is open ends that pass instead -- which is not
/// the failure under test, and made the regression test fail or pass for the wrong reason
/// (cmux#25391 review, 2026-10-26).
static CFRunLoopTimerRef probe_timer;
static int probe_stops;
static int probe_target;
static int probe_ticks;
/// 60 s at 10 ms. A probe that never finds its moment disarms instead of waiting out the test.
static const int probe_tick_cap = 6000;

/// The depth at which the run that a stray stop would be fatal to is the current one: the drain
/// queue's run, plus the one the guard holds inside it when it is holding.
static int guard_floor(void) { return guard_holding ? 2 : 1; }

static void guard_say(const char *message, int number) {
    char line[256];
    int length = snprintf(line, sizeof line, "cmux-next test process: %s (%d)\n", message, number);
    if (length > 0) write(STDERR_FILENO, line, (size_t)length < sizeof line ? (size_t)length : sizeof line - 1);
}

/// Counts only; it never re-enters the loop, so it cannot be asked to fire while it is firing.
static void guard_observe(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    (void)observer;
    (void)info;
    if (activity == kCFRunLoopEntry) {
        run_depth++;
    } else if (activity == kCFRunLoopExit && run_depth > 0) {
        run_depth--;
    }
}

/// A monotonic clock: the wall clock CFAbsoluteTimeGetCurrent reads can step (NTP, a sleeping CI
/// host), and a backwards step would read as a run that took no time and count towards the spin
/// cap below.
static long long guard_now_microseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (long long)now.tv_sec * 1000000 + now.tv_nsec / 1000;
}

/// Runs inside the drain queue's run, before any test does anything, and does not return: from
/// here on, the innermost run of the main run loop is one this function owns.
static void guard_hold_the_main_loop(void) {
    guard_say("holding the main run loop open so a stray stop cannot end this test run", 0);
    while (restarts < restart_cap) {
        long long before = guard_now_microseconds();
        CFRunLoopRun();
        restarts++;
        if (guard_now_microseconds() - before < spin_microseconds) {
            if (++spins >= spin_cap) {
                guard_say("the main run loop will not stay open; standing aside after restarts", restarts);
                return;
            }
        } else {
            spins = 0;
            // Only a real stop is worth a line: a run that lasted is one that was doing the test
            // run's work, and its end is the event this guard exists to survive.
            guard_say("the main run loop was stopped; it is open again, restart", restarts);
        }
    }
    guard_say("standing aside after restarts", restarts);
}

static void probe_disarm(void) {
    if (!probe_timer) return;
    CFRunLoopTimerInvalidate(probe_timer);
    CFRelease(probe_timer);
    probe_timer = NULL;
}

static void probe_fire(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    (void)info;
    if (++probe_ticks >= probe_tick_cap) {
        probe_disarm();
        return;
    }
    // Only when the protected run is the current one. Deeper means a nested pass is open -- a
    // sibling test's, or this test's own -- and stopping that ends the pass, not the run this is
    // about.
    if (run_depth != guard_floor()) return;
    probe_stops++;
    if (probe_stops >= probe_target) probe_disarm();
    CFRunLoopStop(CFRunLoopGetMain());
}

/// Defined beside this file: a run that lists its tests rather than running any.
int cmux_next_test_lists_tests(void);

__attribute__((constructor)) static void cmux_next_test_runloop_guard_install(void) {
    // A listing run reports its tests and ends; holding its run loop open could only hang it, and
    // nothing in a listing run needs the depth count either.
    if (cmux_next_test_lists_tests()) return;
    const char *setting = getenv("CMUX_NEXT_TEST_RUNLOOP_GUARD");
    int hold = !(setting && strcmp(setting, "0") == 0);
    CFRunLoopRef main_loop = CFRunLoopGetMain();
    if (!main_loop) return;
    CFRunLoopObserverRef observer = CFRunLoopObserverCreate(
        NULL, kCFRunLoopEntry | kCFRunLoopExit, true, 0, guard_observe, NULL);
    if (observer) {
        CFRunLoopAddObserver(main_loop, observer, kCFRunLoopCommonModes);
        CFRelease(observer);
    }
    // A run of a mode with nothing in it returns at once. This source is never signalled, so it
    // runs nothing and only keeps the common modes from being empty, which is what lets a restarted
    // run WAIT for the next main-actor job instead of returning straight back into the loop above.
    CFRunLoopSourceContext context;
    memset(&context, 0, sizeof context);
    CFRunLoopSourceRef keepalive = CFRunLoopSourceCreate(NULL, 0, &context);
    if (keepalive) {
        CFRunLoopAddSource(main_loop, keepalive, kCFRunLoopCommonModes);
        CFRelease(keepalive);
    }
    // Queued, not called: the constructor runs while the test bundle loads, before the drain
    // queue's run exists. The block runs on that run's first turn and keeps the main thread from
    // then on, which is the point.
    //
    // Turned off, everything above still happens: the depth count and the keepalive source cost
    // nothing and leave the process exactly as vulnerable as it was, so the regression test can
    // take the same stop and the process really dies of it. Only the holding is skipped.
    if (hold) {
        guard_holding = 1;
        CFRunLoopPerformBlock(main_loop, kCFRunLoopCommonModes, ^{ guard_hold_the_main_loop(); });
        CFRunLoopWakeUp(main_loop);
    }
    guard_installed = hold;
}

int cmux_next_test_runloop_guard_installed(void) {
    return guard_installed;
}

int cmux_next_test_runloop_guard_reentries(void) {
    return restarts;
}

int cmux_next_test_runloop_guard_depth(void) {
    return run_depth;
}

void cmux_next_test_runloop_guard_stop_outermost(int times) {
    if (probe_timer || times < 1) return;
    probe_stops = 0;
    probe_ticks = 0;
    probe_target = times;
    probe_timer = CFRunLoopTimerCreate(
        NULL, CFAbsoluteTimeGetCurrent() + 0.01, 0.01, 0, 0, probe_fire, NULL);
    if (!probe_timer) return;
    CFRunLoopAddTimer(CFRunLoopGetMain(), probe_timer, kCFRunLoopCommonModes);
}

int cmux_next_test_runloop_guard_stopped_outermost(void) {
    return probe_stops;
}

void cmux_next_test_runloop_guard_stop_probing(void) {
    probe_disarm();
}
