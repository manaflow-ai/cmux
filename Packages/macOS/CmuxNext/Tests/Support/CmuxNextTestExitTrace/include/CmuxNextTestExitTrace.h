#ifndef CMUX_NEXT_TEST_EXIT_TRACE_H
#define CMUX_NEXT_TEST_EXIT_TRACE_H
#include "CmuxNextTestSignalPolicy.h" // SwiftPM exports only this umbrella header

/// 1 once the test process's exit() prints its stack (installed when the test bundle loads).
int cmux_next_test_exit_trace_installed(void);

/// 1 once SWIFT_BACKTRACE, if the test process was started with it, is gone from its environment:
/// this process keeps its backtracer and its children (exit tests, privileged tools) do not get one.
int cmux_next_test_backtrace_kept_from_children(void);

/// 1 once the main run loop survives being stopped at its outermost run (installed with the trace).
int cmux_next_test_runloop_guard_installed(void);

/// How many times the guard has entered the main run loop again after it was stopped.
int cmux_next_test_runloop_guard_reentries(void);

/// Runs of the main run loop in the common modes, outermost included: 1 when no nested pass is open.
int cmux_next_test_runloop_guard_depth(void);

/// Stops the run a stray stop would be fatal to, `times` times, each on a turn when that run is
/// the current one. For the guard's own regression test; it works whether or not the guard holds a
/// run, so the same stop can be taken on an unprotected process.
void cmux_next_test_runloop_guard_stop_outermost(int times);

/// How many stops ``cmux_next_test_runloop_guard_stop_outermost`` has landed.
int cmux_next_test_runloop_guard_stopped_outermost(void);

/// Disarms the probe, whether or not it reached its count. Every test that arms it must call this.
void cmux_next_test_runloop_guard_stop_probing(void);

#endif
