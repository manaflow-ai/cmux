#ifndef CMUX_NEXT_TEST_SIGNAL_POLICY_H
#define CMUX_NEXT_TEST_SIGNAL_POLICY_H

/// SIGPIPEs the bundle's handler caught (each one a write to a closed pipe or socket that failed with
/// EPIPE instead of ending the run).
long cmux_next_test_sigpipes(void);

/// Installs the bundle's SIGPIPE handler (the bundle does this once when it loads).
void cmux_next_test_signal_policy_install(void);

/// 1 when SIGPIPE's handler is the bundle's own (not SIG_DFL, SIG_IGN or another handler).
int cmux_next_test_sigpipe_handler_is_current(void);

/// 1 when the handler was in place right after the bundle loaded.
int cmux_next_test_signal_policy_installed_at_load(void);

#endif
