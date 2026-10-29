// A shard's test process died on signal 13 with 19 tests never finished (2026-10-28): a write to
// a pipe whose reader was gone. The app catches SIGPIPE at launch
// (ChildSignalDefaults.installAppSignalPolicy), so there the write fails with EPIPE; the test
// process never ran that step. The bundle takes the same policy when it loads (exec resets it in
// children). The handler calls only async-signal-safe functions (write(2) and a lock-free atomic):
// a stack print (backtrace, backtrace_symbols_fd) can take locks the interrupted thread holds and
// deadlock. The note lands beside the writing test's own "started" line in the log.
#include "CmuxNextTestSignalPolicy.h"

#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>
#include <execinfo.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>

// DIAG (scratch, never merge): stack of a fatal signal, and the SIGPIPE disposition the process inherited.
static void diag_fatal(int sig, siginfo_t *info, void *context) {
    (void)context;
    char line[256];
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    int n = snprintf(line, sizeof line, "DIAG fatal signal %d addr %p code %d thread %llu; stack:\n", sig, info ? info->si_addr : NULL,
                     info ? info->si_code : -1, (unsigned long long)tid);
    write(STDERR_FILENO, line, n);
    void *frames[128];
    int count = backtrace(frames, 128);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
    signal(sig, SIG_DFL);
}

static void diag_install(void) {
    static char stack[1 << 16];
    stack_t alt = {.ss_sp = stack, .ss_size = sizeof stack, .ss_flags = 0};
    sigaltstack(&alt, NULL);
    struct sigaction fatal;
    memset(&fatal, 0, sizeof fatal);
    fatal.sa_sigaction = diag_fatal;
    fatal.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
    sigemptyset(&fatal.sa_mask);
    sigaction(SIGSEGV, &fatal, NULL);
    sigaction(SIGBUS, &fatal, NULL);
}

static _Atomic long sigpipes;

static void sigpipe_caught(int signal) {
    (void)signal;
    int saved = errno;
    if (atomic_fetch_add(&sigpipes, 1) < 3) {
        static const char note[] =
            "cmux-next test process: SIGPIPE caught (a write to a closed pipe or socket; it fails with EPIPE, as in the app)\n";
        (void)write(STDERR_FILENO, note, sizeof note - 1);
        void *frames[64];
        int count = backtrace(frames, 64);
        backtrace_symbols_fd(frames, count, STDERR_FILENO);
    }
    errno = saved;
}

void cmux_next_test_signal_policy_action(struct sigaction *action) {
    memset(action, 0, sizeof *action);
    action->sa_handler = sigpipe_caught;
    action->sa_flags = SA_RESTART;
    sigemptyset(&action->sa_mask);
}

int cmux_next_test_signal_policy_is_handler(const struct sigaction *action) {
    return action->sa_handler == sigpipe_caught;
}

void cmux_next_test_sigpipe_handle(void) {
    sigpipe_caught(SIGPIPE);
}

static int installed_at_load;

// Runs when the bundle loads, before any test: no test can change SIGPIPE between the install and the check.
__attribute__((constructor)) static void cmux_next_test_signal_policy_load(void) {
    struct sigaction action, current, inherited;
    sigaction(SIGPIPE, NULL, &inherited);
    {
        char line[160];
        int n = snprintf(line, sizeof line, "DIAG pid %d: SIGPIPE inherited as %s\n", getpid(),
                         inherited.sa_handler == SIG_DFL ? "SIG_DFL" : inherited.sa_handler == SIG_IGN ? "SIG_IGN" : "a handler");
        write(STDERR_FILENO, line, n);
    }
    diag_install();
    cmux_next_test_signal_policy_action(&action);
    sigaction(SIGPIPE, &action, NULL);
    installed_at_load = sigaction(SIGPIPE, NULL, &current) == 0 && cmux_next_test_signal_policy_is_handler(&current);
}

int cmux_next_test_signal_policy_installed_at_load(void) {
    return installed_at_load;
}

long cmux_next_test_sigpipes(void) {
    return atomic_load(&sigpipes);
}
