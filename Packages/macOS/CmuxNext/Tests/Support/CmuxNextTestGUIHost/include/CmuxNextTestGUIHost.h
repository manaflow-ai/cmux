#ifndef CMUX_NEXT_TEST_GUI_HOST_H
#define CMUX_NEXT_TEST_GUI_HOST_H

/// 1 once the test process has a running NSApplication (installed when the test bundle loads, on the main thread's
/// first run-loop turn); 0 before or when it is not a GUI test run.
int cmux_next_test_gui_host_running(void);

/// 1 once the host also made the process a regular app that has finished launching: only when the run set
/// `CMUX_CI_CONSOLE_SESSION=1` (fleet gui-session-v1 steps) or `CMUX_TEST_REQUIRE_GUI=1`. It never activates: a suite
/// that needs an active app carries `.guiApp` (CmuxNextTestGUI), which activates per test and skips without it.
int cmux_next_test_gui_host_launched(void);

#endif
