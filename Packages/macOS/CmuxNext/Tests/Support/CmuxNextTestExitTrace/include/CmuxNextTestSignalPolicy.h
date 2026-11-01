#ifndef CMUX_NEXT_TEST_SIGNAL_POLICY_H
#define CMUX_NEXT_TEST_SIGNAL_POLICY_H

#include <signal.h>

/// SIGPIPEs the bundle's handler caught (each one a write to a closed pipe or socket that failed with
/// EPIPE instead of ending the run).
long cmux_next_test_sigpipes(void);

/// Fills `action` with the disposition the bundle installs for SIGPIPE when it loads.
void cmux_next_test_signal_policy_action(struct sigaction *action);

/// 1 when `action`'s handler is the bundle's own (not SIG_DFL, SIG_IGN or another handler).
int cmux_next_test_signal_policy_is_handler(const struct sigaction *action);

/// Runs the bundle's handler as a delivered SIGPIPE would, with no signal sent.
void cmux_next_test_sigpipe_handle(void);

/// 1 when SIGPIPE's handler was the bundle's own right after the bundle loaded, before any test ran.
int cmux_next_test_signal_policy_installed_at_load(void);

#endif
