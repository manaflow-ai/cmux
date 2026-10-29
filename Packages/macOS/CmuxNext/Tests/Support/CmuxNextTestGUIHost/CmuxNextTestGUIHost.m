// The test process as an app: under `swift test` the main thread runs the Swift concurrency main loop
// (CFRunLoopRun) and nothing dispatches NSApplication's events, so the process never finishes launching, never
// becomes active, has no key window, and AppKit work that waits on an event (activation, a key change) never
// lands. Fleet probe S7ActivationProbeTests (0ba1d205 on cmux11s, 9a183366 on cmuxs-Mac-mini-4, console session):
// with no event dispatch the process stayed inactive after setActivationPolicy(.regular) and finishLaunching;
// dispatching NSApp's events made activate succeed (active, key and main window), also with a system alert
// frontmost. Linked into the test bundle only: when the bundle loads, this queues one setup on the main
// queue that dispatches NSApp's pending events on every main run-loop turn, as NSApplication.run would (harmless
// on any Mac). Only a run that asks for a GUI (`CMUX_TEST_REQUIRE_GUI=1`, which the fleet's gui-session-v1 steps
// set) also finishes launching as a regular app and activates: a person running `swift test` on their own Mac
// keeps their focus. A listing run (`swift test list`) does nothing.
#import <AppKit/AppKit.h>
#include <crt_externs.h>
#include <stdlib.h>
#include <string.h>

#include "CmuxNextTestGUIHost.h"

static int running;
static int activated;

/// The run asked for a GUI: the fleet's gui-session-v1 steps, or a person who opts in.
static int requires_gui(void) {
    const char *value = getenv("CMUX_TEST_REQUIRE_GUI");
    return value != NULL && strcmp(value, "1") == 0;
}

/// Sends every event NSApp has queued now; never waits.
static void dispatch_pending_events(void) {
    for (;;) {
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast]
                                                inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event == nil) return;
        [NSApp sendEvent:event];
    }
}

/// A run that lists or dumps its tests instead of running them.
static int lists_tests(void) {
    int count = *_NSGetArgc();
    char **arguments = *_NSGetArgv();
    for (int index = 1; index < count; index++) {
        if (strncmp(arguments[index], "--list", 6) == 0 || strncmp(arguments[index], "--dump", 6) == 0) return 1;
    }
    return 0;
}

static void start_gui_host(void) {
    [NSApplication sharedApplication];
    int gui = requires_gui();
    if (gui) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
    }
    // Before each wait of the main run loop: dispatch what NSApp has queued (activation, key and mouse changes).
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopAfterWaiting, true, 0,
        ^(CFRunLoopObserverRef ref, CFRunLoopActivity activity) {
            (void)ref; (void)activity;
            dispatch_pending_events();
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    CFRelease(observer);
    if (gui) {
        [NSApp activateIgnoringOtherApps:YES];
        activated = 1;
    }
    dispatch_pending_events();
    running = 1;
}

__attribute__((constructor)) static void cmux_next_test_gui_host_install(void) {
    if (lists_tests()) return;
    // On the main queue, so AppKit starts on the main thread once the test runner drains it.
    dispatch_async(dispatch_get_main_queue(), ^{ start_gui_host(); });
}

int cmux_next_test_gui_host_running(void) {
    return running;
}

int cmux_next_test_gui_host_activated(void) {
    return activated;
}
