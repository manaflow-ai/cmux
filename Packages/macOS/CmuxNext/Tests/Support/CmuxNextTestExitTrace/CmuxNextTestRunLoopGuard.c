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
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
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

// Every Core Animation commit in this process lays out each window that needs it, so windows the
// tests leave open slow every later main-actor test (a 500-row sidebar scroll bench took over
// 300 s in a process that had run other window suites first). Every 30 s, when the count moved,
// the guard pass says how many windows the process holds, how many are on screen or need layout,
// and the classes that hold the most, so a run that slows down names what piled up.
static long census_last = -1;

static void window_census(void) {
    id *app_slot = (id *)dlsym(RTLD_DEFAULT, "NSApp");
    if (app_slot == NULL || *app_slot == nil) return;
    id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    unsigned long (*count_of)(id, SEL) = (unsigned long (*)(id, SEL))objc_msgSend;
    id (*at)(id, SEL, unsigned long) = (id (*)(id, SEL, unsigned long))objc_msgSend;
    signed char (*flag)(id, SEL) = (signed char (*)(id, SEL))objc_msgSend;
    id windows = send(*app_slot, sel_registerName("windows"));
    long total = (long)count_of(windows, sel_registerName("count"));
    if (total == census_last) return;
    census_last = total;
    enum { kinds = 4 };
    const char *names[kinds] = {0};
    long counts[kinds] = {0};
    long visible = 0, need_layout = 0;
    for (long index = 0; index < total; index++) {
        id window = at(windows, sel_registerName("objectAtIndex:"), (unsigned long)index);
        if (flag(window, sel_registerName("isVisible"))) visible++;
        id content = send(window, sel_registerName("contentView"));
        if (content != nil && flag(content, sel_registerName("needsLayout"))) need_layout++;
        const char *name = object_getClassName(window);
        int slot = 0;
        while (slot < kinds && names[slot] != NULL && strcmp(names[slot], name) != 0) slot++;
        if (slot == kinds) continue;
        names[slot] = name;
        counts[slot]++;
    }
    char line[512];
    int length = snprintf(line, sizeof line, "cmux-next test process: %ld windows open (%ld on screen, %ld need layout)", total,
                          visible, need_layout);
    for (int slot = 0; slot < kinds && names[slot] != NULL && length > 0 && (size_t)length < sizeof line; slot++)
        length += snprintf(line + length, sizeof line - (size_t)length, "%s %s %ld", slot == 0 ? ";" : ",", names[slot],
                           counts[slot]);
    if (length > 0 && (size_t)length < sizeof line - 1) line[length++] = '\n';
    if (length > 0) write(STDERR_FILENO, line, (size_t)length < sizeof line ? (size_t)length : sizeof line - 1);
}

static void run_guard_pass(void) {
    atomic_store(&guard_running, 1);
    // A far-off timer keeps the default mode from reading as empty, so a pass waits for work
    // instead of returning "finished" at once.
    CFRunLoopTimerRef keep = CFRunLoopTimerCreateWithHandler(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0,
                                                             ^(CFRunLoopTimerRef timer) { (void)timer; });
    CFRunLoopAddTimer(CFRunLoopGetMain(), keep, kCFRunLoopDefaultMode);
    // Stop condition: none of its own; it ends with the test process, as the pass does.
    CFRunLoopTimerRef census = CFRunLoopTimerCreateWithHandler(NULL, CFAbsoluteTimeGetCurrent() + 30, 30, 0, 0,
                                                               ^(CFRunLoopTimerRef timer) { (void)timer; window_census(); });
    CFRunLoopAddTimer(CFRunLoopGetMain(), census, kCFRunLoopDefaultMode);
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
