// A stray stop of the main run loop ended the whole test run, quietly.
//
// `swift_task_asyncMainDrainQueue` runs the main run loop and calls `exit(0)` the moment that run
// returns, so `main` never comes back to the test runner: the tests still in flight never report,
// and swift-testing never prints its summary line. Anything that calls `CFRunLoopStop` while the
// outermost run is the current one does this, whether it is a test that means to end its own
// nested pass and is a turn late, or AppKit waking an event wait
// (`-[NSEvent _postAtStart:]` calls `CFRunLoopStop`).
//
// Run 40317841968 is the shape: the exit stack was `main` -> `swift_task_asyncMainDrainQueue` ->
// `exit`, 2793 tests had started and never finished, and before the reporting gate in
// scripts/cmux-next/swift-test-with-hang-sampler.sh the job still read as a pass.
//
// So the outermost run is made to survive being stopped: an observer sees the run at depth 0
// returning and enters the main run loop again, which goes on draining the main-actor jobs the
// test run is made of. A finished run does not end this way and cannot be kept alive by accident:
// swift-testing calls `exit()` itself, from its own job on a dispatch worker thread (its stack in
// the same log), which ends the process at any run depth.
//
// Each re-entry prints a line, and after `reentry_cap` of them the guard stands aside, so a
// process that is being stopped in a loop ends rather than growing its stack without limit; the
// reporting gate turns that into a red job. `CMUX_NEXT_TEST_RUNLOOP_GUARD=0` turns the guard off,
// which is how its regression test is proven red on the same binary.
#include "CmuxNextTestExitTrace.h"

#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int guard_installed;
/// Runs of the main run loop in the common modes, outermost first. A nested pass in a private mode
/// is not counted, and must not be: stopping one of those ends that pass, not the outermost run.
static int run_depth;
static int reentries;
static const int reentry_cap = 64;

/// The test probe below: a timer that stops the outermost run the way a real stray stop reaches it.
static CFRunLoopTimerRef probe_timer;
static int probe_stopped;

static void guard_say(const char *message, int number) {
    char line[256];
    int length = snprintf(line, sizeof line, "cmux-next test process: %s (%d)\n", message, number);
    if (length > 0) write(STDERR_FILENO, line, (size_t)length < sizeof line ? (size_t)length : sizeof line - 1);
}

static void guard_observe(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    (void)observer;
    (void)info;
    if (activity == kCFRunLoopEntry) {
        run_depth++;
        return;
    }
    if (activity != kCFRunLoopExit) return;
    if (run_depth > 0) run_depth--;
    // Only the outermost run's return reaches swift_task_asyncMainDrainQueue's exit(0).
    if (run_depth != 0) return;
    if (reentries >= reentry_cap) {
        guard_say("the main run loop was stopped again at its outermost run; standing aside after re-entries", reentries);
        return;
    }
    reentries++;
    guard_say("the main run loop was stopped at its outermost run, which would end this test run; entering it again, re-entry", reentries);
    // Inside the exit callout, so this is a new run of the same loop: it drains the main-actor jobs
    // the rest of the test run is made of, and ends when swift-testing calls exit().
    CFRunLoopRun();
}

static void probe_fire(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    (void)info;
    // Wait for a turn with no nested pass open: a stop taken inside one of those ends that pass
    // instead, which is not the failure under test.
    if (run_depth != 1) return;
    probe_stopped = 1;
    if (probe_timer) {
        CFRunLoopTimerInvalidate(probe_timer);
        CFRelease(probe_timer);
        probe_timer = NULL;
    }
    CFRunLoopStop(CFRunLoopGetMain());
}

/// Defined beside this file: a run that lists its tests rather than running any.
int cmux_next_test_lists_tests(void);

__attribute__((constructor)) static void cmux_next_test_runloop_guard_install(void) {
    const char *setting = getenv("CMUX_NEXT_TEST_RUNLOOP_GUARD");
    if (setting && strcmp(setting, "0") == 0) return;
    // A listing run reports its tests and ends; keeping its run loop alive could only hang it.
    if (cmux_next_test_lists_tests()) return;
    CFRunLoopObserverRef observer = CFRunLoopObserverCreate(
        NULL, kCFRunLoopEntry | kCFRunLoopExit, true, 0, guard_observe, NULL);
    if (!observer) return;
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    CFRelease(observer);
    // A run of a mode with nothing in it returns at once, which would spend the whole re-entry
    // budget in a moment and end the process anyway. This source is never signalled, so it keeps
    // the common modes from being empty and never runs anything.
    CFRunLoopSourceContext context;
    memset(&context, 0, sizeof context);
    CFRunLoopSourceRef keepalive = CFRunLoopSourceCreate(NULL, 0, &context);
    if (keepalive) {
        CFRunLoopAddSource(CFRunLoopGetMain(), keepalive, kCFRunLoopCommonModes);
        CFRelease(keepalive);
    }
    guard_installed = 1;
}

int cmux_next_test_runloop_guard_installed(void) {
    return guard_installed;
}

int cmux_next_test_runloop_guard_reentries(void) {
    return reentries;
}

int cmux_next_test_runloop_guard_depth(void) {
    return run_depth;
}

void cmux_next_test_runloop_guard_stop_outermost(void) {
    if (probe_timer) return;
    probe_stopped = 0;
    probe_timer = CFRunLoopTimerCreate(
        NULL, CFAbsoluteTimeGetCurrent() + 0.01, 0.01, 0, 0, probe_fire, NULL);
    if (!probe_timer) return;
    CFRunLoopAddTimer(CFRunLoopGetMain(), probe_timer, kCFRunLoopCommonModes);
}

int cmux_next_test_runloop_guard_stopped_outermost(void) {
    return probe_stopped;
}
