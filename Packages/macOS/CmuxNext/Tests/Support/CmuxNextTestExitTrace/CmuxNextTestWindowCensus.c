// Windows the tests leave open pile up in the one test process: the broad Swift pass went from 3
// to 428 windows (2026-10-28), and since every Core Animation commit lays out each window that
// needs it, later tests slowed from about 2,000 a minute to about 100 and the pass was cut short.
//
// Linked into the test bundle only. When the bundle loads, every NSWindow (NSPanel included) is
// tagged at init with the suite and test that created it, read from swift-testing's Test.current
// by `cmux_next_test_window_owner` (CmuxNextTestSupport/WindowLeakCheck.swift). Two methods read
// a tag without a header: -cmuxNextTestOwner (the "Module.Suite\ttest()" string, or nil) and
// -cmuxNextTestWasClosed (YES after -close, NO again once the window is ordered back in). The
// `.closesItsWindows` suite trait uses them to close and name what its suite left open. When the
// process exits, a census names, per suite, the windows still open, so a suite without the trait
// that leaks is named too. A listing (`swift test list`) is left alone.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGGeometry.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char owner_key;
static char closed_key;

typedef id (*init4_fn)(id, SEL, CGRect, unsigned long, unsigned long, signed char);
typedef id (*init5_fn)(id, SEL, CGRect, unsigned long, unsigned long, signed char, id);
typedef void (*close_fn)(id, SEL);
typedef void (*order_fn)(id, SEL, long, long);

static init4_fn original_init4;
static init5_fn original_init5;
static close_fn original_close;
static order_fn original_order;

static int lists_tests(void) {
    int count = *_NSGetArgc();
    char **arguments = *_NSGetArgv();
    for (int index = 1; index < count; index++) {
        if (strncmp(arguments[index], "--list", 6) == 0 || strncmp(arguments[index], "--dump", 6) == 0) return 1;
    }
    return 0;
}

// Windows created per suite, so the census can say "left 3 of 40 open". Main thread only (AppKit
// creates windows there); a fixed table, and a suite past its size is counted under "other".
enum { max_suites = 4096 };
static char *created_suites[max_suites];
static long created_counts[max_suites];
static long created_suite_total;

static void count_created(const char *owner) {
    size_t length = strcspn(owner, "\t");
    long slot = 0;
    for (; slot < created_suite_total; slot++) {
        if (strlen(created_suites[slot]) == length && strncmp(created_suites[slot], owner, length) == 0) break;
    }
    if (slot == created_suite_total) {
        if (created_suite_total == max_suites) return;
        created_suites[slot] = strndup(owner, length);
        created_suite_total++;
    }
    created_counts[slot]++;
}

static void tag(id window) {
    if (window == nil || objc_getAssociatedObject(window, &owner_key) != nil) return;
    static char *(*owner_of_current_test)(void);
    static int resolved;
    if (!resolved) {
        resolved = 1;
        owner_of_current_test = (char *(*)(void))dlsym(RTLD_SELF, "cmux_next_test_window_owner");
        if (owner_of_current_test == NULL) owner_of_current_test = (char *(*)(void))dlsym(RTLD_DEFAULT, "cmux_next_test_window_owner");
    }
    char *owner = owner_of_current_test != NULL ? owner_of_current_test() : NULL;
    const char *text = owner != NULL ? owner : "(no test)\t";
    count_created(text);
    CFStringRef value = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    free(owner);
    if (value == NULL) return;
    objc_setAssociatedObject(window, &owner_key, (id)value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CFRelease(value);
}

static id tagging_init4(id self, SEL command, CGRect rect, unsigned long style, unsigned long backing, signed char defer) {
    id window = original_init4(self, command, rect, style, backing, defer);
    tag(window);
    return window;
}

static id tagging_init5(id self, SEL command, CGRect rect, unsigned long style, unsigned long backing, signed char defer, id screen) {
    id window = original_init5(self, command, rect, style, backing, defer, screen);
    tag(window);
    return window;
}

static void marking_close(id self, SEL command) {
    objc_setAssociatedObject(self, &closed_key, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    original_close(self, command);
}

// -orderWindow:relativeTo: is where every order-in and order-out lands; ordering in (any place but
// NSWindowOut, 0) reopens a closed window.
static void marking_order(id self, SEL command, long place, long other) {
    if (place != 0) objc_setAssociatedObject(self, &closed_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    original_order(self, command, place, other);
}

static id read_owner(id self, SEL command) {
    (void)command;
    return objc_getAssociatedObject(self, &owner_key);
}

static signed char read_closed(id self, SEL command) {
    (void)command;
    return objc_getAssociatedObject(self, &closed_key) != nil;
}

// A window of a private AppKit class (TUINSWindow, SPRoundedWindow: not NSWindow or NSPanel
// themselves), which AppKit makes and keeps on its own; the census counts these apart.
static int is_appkits_own(id window) {
    Class window_class = object_getClass(window);
    while (window_class != Nil && strncmp(class_getName(window_class), "NSKVONotifying_", 15) == 0)
        window_class = class_getSuperclass(window_class);
    if (window_class == Nil || window_class == objc_getClass("NSWindow") || window_class == objc_getClass("NSPanel")) return 0;
    const char *image = class_getImageName(window_class);
    return image != NULL && strncmp(image, "/System/", 8) == 0;
}

static IMP swap(Class window_class, const char *name, IMP replacement) {
    Method method = class_getInstanceMethod(window_class, sel_registerName(name));
    return method != NULL ? method_setImplementation(method, replacement) : NULL;
}

// The census at exit: for each suite with windows still open, how many of the windows it created
// are open, how many on screen, their classes and a few titles. The walk reads NSApp's window list
// once, after the run; it changes nothing.
static void census_at_exit(void) {
    id *app_slot = (id *)dlsym(RTLD_DEFAULT, "NSApp");
    if (app_slot == NULL || *app_slot == nil) return;
    id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    unsigned long (*count_of)(id, SEL) = (unsigned long (*)(id, SEL))objc_msgSend;
    id (*at)(id, SEL, unsigned long) = (id (*)(id, SEL, unsigned long))objc_msgSend;
    signed char (*flag)(id, SEL) = (signed char (*)(id, SEL))objc_msgSend;
    id windows = send(*app_slot, sel_registerName("windows"));
    long total = (long)count_of(windows, sel_registerName("count"));
    long open = 0, visible = 0, closed_alive = 0, appkits_own = 0;
    char line[1024];
    // One pass per suite that still has an open window: the window lists are small (hundreds).
    char *reported[max_suites];
    long reported_count = 0;
    for (long index = 0; index < total; index++) {
        id window = at(windows, sel_registerName("objectAtIndex:"), (unsigned long)index);
        if (read_closed(window, NULL)) { closed_alive++; continue; }
        if (is_appkits_own(window)) { appkits_own++; continue; }
        open++;
        if (flag(window, sel_registerName("isVisible"))) visible++;
    }
    int length = snprintf(line, sizeof line,
                          "cmux-next window census at exit: %ld windows open (%ld on screen), %ld more closed but still alive, "
                          "%ld of AppKit's own, %ld suites created windows\n",
                          open, visible, closed_alive, appkits_own, created_suite_total);
    if (length > 0) write(STDERR_FILENO, line, (size_t)length < sizeof line ? (size_t)length : sizeof line - 1);
    for (long index = 0; index < total; index++) {
        id window = at(windows, sel_registerName("objectAtIndex:"), (unsigned long)index);
        if (read_closed(window, NULL) || is_appkits_own(window)) continue;
        CFStringRef owner_value = (CFStringRef)read_owner(window, NULL);
        char owner[512] = "(created before the census was installed)\t";
        if (owner_value != NULL && !CFStringGetCString(owner_value, owner, sizeof owner, kCFStringEncodingUTF8)) strcpy(owner, "(unreadable)");
        size_t suite_length = strcspn(owner, "\t");
        owner[suite_length] = '\0';
        int seen = 0;
        for (long slot = 0; slot < reported_count && !seen; slot++) seen = strcmp(reported[slot], owner) == 0;
        if (seen || reported_count == max_suites) continue;
        reported[reported_count++] = strdup(owner);
        long suite_open = 0, suite_visible = 0;
        char details[600] = "";
        size_t details_length = 0;
        for (long other = index; other < total; other++) {
            id candidate = at(windows, sel_registerName("objectAtIndex:"), (unsigned long)other);
            if (read_closed(candidate, NULL) || is_appkits_own(candidate)) continue;
            CFStringRef candidate_value = (CFStringRef)read_owner(candidate, NULL);
            char candidate_owner[512] = "(created before the census was installed)\t";
            if (candidate_value != NULL && !CFStringGetCString(candidate_value, candidate_owner, sizeof candidate_owner, kCFStringEncodingUTF8))
                strcpy(candidate_owner, "(unreadable)");
            candidate_owner[strcspn(candidate_owner, "\t")] = '\0';
            if (strcmp(candidate_owner, owner) != 0) continue;
            suite_open++;
            if (flag(candidate, sel_registerName("isVisible"))) suite_visible++;
            if (suite_open <= 4 && details_length < sizeof details - 1) {
                CFStringRef title = (CFStringRef)send(candidate, sel_registerName("title"));
                char title_text[80] = "";
                if (title != NULL && !CFStringGetCString(title, title_text, sizeof title_text, kCFStringEncodingUTF8)) title_text[0] = '\0';
                int added = snprintf(details + details_length, sizeof details - details_length, "%s%s \"%s\"",
                                     suite_open == 1 ? "" : ", ", object_getClassName(candidate), title_text);
                if (added > 0) details_length += (size_t)added < sizeof details - details_length ? (size_t)added : sizeof details - details_length - 1;
            }
        }
        long created = 0;
        for (long slot = 0; slot < created_suite_total; slot++) {
            if (strcmp(created_suites[slot], owner) == 0) created = created_counts[slot];
        }
        length = snprintf(line, sizeof line, "cmux-next window leak: %s left %ld of the %ld windows it created open (%ld on screen): %s%s\n",
                          owner, suite_open, created, suite_visible, details, suite_open > 4 ? ", ..." : "");
        if (length > 0) write(STDERR_FILENO, line, (size_t)length < sizeof line ? (size_t)length : sizeof line - 1);
    }
}

__attribute__((constructor)) static void cmux_next_test_window_census_install(void) {
    if (lists_tests()) return;
    Class window_class = objc_getClass("NSWindow");
    if (window_class == Nil) return;
    original_init4 = (init4_fn)swap(window_class, "initWithContentRect:styleMask:backing:defer:", (IMP)tagging_init4);
    original_init5 = (init5_fn)swap(window_class, "initWithContentRect:styleMask:backing:defer:screen:", (IMP)tagging_init5);
    original_close = (close_fn)swap(window_class, "close", (IMP)marking_close);
    original_order = (order_fn)swap(window_class, "orderWindow:relativeTo:", (IMP)marking_order);
    class_addMethod(window_class, sel_registerName("cmuxNextTestOwner"), (IMP)read_owner, "@@:");
    class_addMethod(window_class, sel_registerName("cmuxNextTestWasClosed"), (IMP)read_closed, "c@:");
    atexit(census_at_exit);
}
