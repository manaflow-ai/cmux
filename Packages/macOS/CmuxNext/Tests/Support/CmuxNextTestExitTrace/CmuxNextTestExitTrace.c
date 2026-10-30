// The Swift test helper ended with status 0 in the middle of CmuxNextAppTests, leaving hundreds
// of tests "started and never finished" with no crash report: something in the process called
// exit() (NSApp.terminate in a process whose app never ran ends that way). Linked into the test
// bundle only: when the bundle loads, every exit() of the test process prints its stack to stderr,
// so the caller is named in the CI log. A finished run prints one stack too, from the test
// runner's own exit at the end. A listing (`swift test list`) prints nothing: SwiftPM reads its
// output as the list of tests.
#include "CmuxNextTestExitTrace.h"

#include <crt_externs.h>
#include <execinfo.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int installed;

static void cmux_next_test_exit_trace(void) {
    static const char header[] = "cmux-next test process: exit() called (a stack at the very end of a run is the runner's own); its stack:\n";
    write(STDERR_FILENO, header, sizeof header - 1);
    void *frames[96];
    int count = backtrace(frames, 96);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
}

/// A run that lists or dumps its tests (`--list-tests`, `--dump-tests-json`) instead of running them.
/// Shared with the run-loop guard beside this file, so both read one answer.
int cmux_next_test_lists_tests(void) {
    int count = *_NSGetArgc();
    char **arguments = *_NSGetArgv();
    for (int index = 1; index < count; index++) {
        if (strncmp(arguments[index], "--list", 6) == 0 || strncmp(arguments[index], "--dump", 6) == 0) return 1;
    }
    return 0;
}

__attribute__((constructor)) static void cmux_next_test_exit_trace_install(void) {
    installed = cmux_next_test_lists_tests() || atexit(cmux_next_test_exit_trace) == 0;
}

int cmux_next_test_exit_trace_installed(void) {
    return installed;
}
