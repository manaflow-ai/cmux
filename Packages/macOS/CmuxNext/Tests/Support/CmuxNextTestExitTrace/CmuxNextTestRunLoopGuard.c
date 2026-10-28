// The Swift test helper ended with status 0 mid-run on every feat-cmux-next tip (2026-10-28):
// no "Test run with" summary, thousands of tests started and never finished, and the exit()
// stack was exit <- swift_task_asyncMainDrainQueue. swift-testing's async main runs the main
// run loop with CFRunLoopRun() and calls exit(0) when it returns, so any CFRunLoopStop that
// reaches that outermost loop ends the whole test process: a test's own CFRunLoopStop that
// outlived its nested pass, or NSApp.postEvent (-[NSEvent _postAtStart:] calls CFRunLoopStop
// to wake an event wait) from a main-actor job. #24424 moved one such caller into a nested pass;
// the next caller ended the run again.
//
// Here the process keeps one pass of its own running under that outermost loop, for the test
// helper only: a stop ends this pass, which says so on stderr and runs again, so the
// outermost loop never returns and the run reaches its summary. A real end is swift-testing's
// own exit() from a worker thread, which needs no main run loop. The xctest process (which
// runs the main loop only inside its waits) and a listing (`swift test list`) are left alone.
#include "CmuxNextTestExitTrace.h"

#include <CoreFoundation/CoreFoundation.h>
#include <crt_externs.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static _Atomic int guard_installed;
static _Atomic int guard_running;
static _Atomic long guard_stops;

static int is_swift_testing_helper(void) {
    const char *name = getprogname();
    if (name == NULL || strcmp(name, "swiftpm-testing-helper") != 0) return 0;
    int count = *_NSGetArgc();
    char **arguments = *_NSGetArgv();
    for (int index = 1; index < count; index++) {
        if (strncmp(arguments[index], "--list", 6) == 0 || strncmp(arguments[index], "--dump", 6) == 0) return 0;
    }
    return 1;
}

static void run_guard_pass(void) {
    atomic_store(&guard_running, 1);
    // A far-off timer keeps the default mode from reading as empty, so a pass waits for work
    // instead of returning "finished" at once.
    CFRunLoopTimerRef keep = CFRunLoopTimerCreateWithHandler(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0,
                                                             ^(CFRunLoopTimerRef timer) { (void)timer; });
    CFRunLoopAddTimer(CFRunLoopGetMain(), keep, kCFRunLoopDefaultMode);
    for (;;) {
        // Not CFRunLoopRun(): it returns on "finished" too, which would spin here.
        CFRunLoopRunResult result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1e9, false);
        if (result == kCFRunLoopRunStopped) {
            long stops = atomic_fetch_add(&guard_stops, 1) + 1;
            char line[256];
            int length = snprintf(line, sizeof line,
                                  "cmux-next test process: the outermost main run loop was stopped (stop %ld: a CFRunLoopStop or "
                                  "NSApp.postEvent from a main-actor job); kept running so the test run finishes\n",
                                  stops);
            if (length > 0) write(STDERR_FILENO, line, (size_t)length < sizeof line ? (size_t)length : sizeof line - 1);
        }
    }
}

__attribute__((constructor)) static void cmux_next_test_run_loop_guard_install(void) {
    if (!is_swift_testing_helper()) return;
    // A one-shot timer due now fires in the main loop's first default-mode pass:
    // swift-testing's CFRunLoopRun(). Not a main-queue job (a pass run inside one never serves
    // the main queue again) and not a CFRunLoopPerformBlock (blocks queued behind it in the same
    // batch would wait for it, forever).
    CFRunLoopTimerRef start = CFRunLoopTimerCreateWithHandler(NULL, CFAbsoluteTimeGetCurrent(), 0, 0, 0,
                                                              ^(CFRunLoopTimerRef timer) { (void)timer; run_guard_pass(); });
    CFRunLoopAddTimer(CFRunLoopGetMain(), start, kCFRunLoopDefaultMode);
    atomic_store(&guard_installed, 1);
}

int cmux_next_test_run_loop_guard_installed(void) {
    return atomic_load(&guard_installed);
}

int cmux_next_test_run_loop_guard_running(void) {
    return atomic_load(&guard_running);
}

long cmux_next_test_run_loop_guard_stops(void) {
    return atomic_load(&guard_stops);
}
