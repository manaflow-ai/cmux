#ifndef CMUX_NEXT_TEST_GUI_HOST_H
#define CMUX_NEXT_TEST_GUI_HOST_H

/// 1 once the test process has a running NSApplication (installed when the test bundle loads, on the main thread's
/// first run-loop turn); 0 before or when it is not a GUI test run.
int cmux_next_test_gui_host_running(void);

/// 1 once the host also made the process a regular, active app: only when the run set `CMUX_CI_CONSOLE_SESSION=1` (fleet gui-session-v1 steps) or `CMUX_TEST_REQUIRE_GUI=1`
/// (a person's own `swift test` keeps their focus). Suites that need an active app skip without it.
int cmux_next_test_gui_host_activated(void);

#endif
