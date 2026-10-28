#ifndef CMUX_NEXT_TEST_SIGNAL_POLICY_H
#define CMUX_NEXT_TEST_SIGNAL_POLICY_H

/// SIGPIPEs the test process caught (each one a write to a closed pipe or socket that failed with
/// EPIPE instead of ending the run).
long cmux_next_test_sigpipes(void);

#endif
