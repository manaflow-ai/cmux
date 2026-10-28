#ifndef CMUX_NEXT_TEST_EXIT_TRACE_H
#define CMUX_NEXT_TEST_EXIT_TRACE_H

/// 1 once the test process's exit() prints its stack (installed when the test bundle loads).
int cmux_next_test_exit_trace_installed(void);

/// 1 once the swift-testing helper keeps its outermost main run loop running (CmuxNextTestRunLoopGuard.c).
int cmux_next_test_run_loop_guard_installed(void);

/// 1 once that guard's pass runs under the outermost main run loop.
int cmux_next_test_run_loop_guard_running(void);

/// How many stops reached the outermost main run loop and were kept from ending the test run.
long cmux_next_test_run_loop_guard_stops(void);

#endif
