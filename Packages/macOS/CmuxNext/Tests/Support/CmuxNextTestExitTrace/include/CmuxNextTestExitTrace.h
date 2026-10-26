#ifndef CMUX_NEXT_TEST_EXIT_TRACE_H
#define CMUX_NEXT_TEST_EXIT_TRACE_H

/// 1 once the test process's exit() prints its stack (installed when the test bundle loads).
int cmux_next_test_exit_trace_installed(void);

/// 1 once the main run loop survives being stopped at its outermost run (installed with the trace).
int cmux_next_test_runloop_guard_installed(void);

/// How many times the guard has entered the main run loop again after it was stopped.
int cmux_next_test_runloop_guard_reentries(void);

/// Runs of the main run loop in the common modes, outermost included: 1 when no nested pass is open.
int cmux_next_test_runloop_guard_depth(void);

/// Stops the main run loop on the next turn with no nested pass open, the way a stray stop reaches
/// the outermost run. For the guard's own regression test.
void cmux_next_test_runloop_guard_stop_outermost(void);

/// 1 once ``cmux_next_test_runloop_guard_stop_outermost`` has stopped the outermost run.
int cmux_next_test_runloop_guard_stopped_outermost(void);

#endif
