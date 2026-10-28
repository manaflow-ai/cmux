// A shard's test process died on signal 13 with 19 tests never finished (2026-10-28): a write to
// a pipe whose reader was gone. The app catches SIGPIPE at launch
// (ChildSignalDefaults.installAppSignalPolicy), so there the write fails with EPIPE; the test
// process never ran that step. The bundle takes the same policy when it loads (exec resets it in
// children), and the first few catches print the writer's stack on stderr.
#include "CmuxNextTestSignalPolicy.h"

#include <execinfo.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

static _Atomic long sigpipes;

static void sigpipe_caught(int signal) {
    (void)signal;
    long count = atomic_fetch_add(&sigpipes, 1) + 1;
    if (count > 3) return;
    static const char header[] =
        "cmux-next test process: SIGPIPE caught (a write to a closed pipe or socket; it fails with EPIPE, as in the app); "
        "the writer's stack:\n";
    write(STDERR_FILENO, header, sizeof header - 1);
    void *frames[64];
    int depth = backtrace(frames, 64);
    backtrace_symbols_fd(frames, depth, STDERR_FILENO);
}

__attribute__((constructor)) static void cmux_next_test_signal_policy_install(void) {
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = sigpipe_caught;
    action.sa_flags = SA_RESTART;
    sigemptyset(&action.sa_mask);
    sigaction(SIGPIPE, &action, NULL);
}

long cmux_next_test_sigpipes(void) {
    return atomic_load(&sigpipes);
}
