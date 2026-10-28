// A test process ended on signal 13 with 19 tests started and never finished (feat-cmux-next
// swift test, 2026-10-28, an AgentPane shard): something wrote to a pipe or socket whose reader
// was gone, and SIGPIPE's default action ended the whole run. The app never dies that way:
// ChildSignalDefaults.installAppSignalPolicy() catches SIGPIPE at launch with a no-op handler, so
// the write fails with EPIPE. The test process never ran that launch step, so product code under
// test was held to a rule the app does not have, and one late write took every test in the
// process with it.
//
// So the test bundle takes the app's SIGPIPE policy when it loads: a caught SIGPIPE (exec resets
// it to the default in every child, as in the app), and the write fails with EPIPE. The first few
// print the writer's stack on stderr, so a test that writes after its peer is gone is still
// named in the CI log.
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
