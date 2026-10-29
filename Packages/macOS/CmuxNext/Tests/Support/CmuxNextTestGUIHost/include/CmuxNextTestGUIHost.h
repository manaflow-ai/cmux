#ifndef CMUX_NEXT_TEST_GUI_HOST_H
#define CMUX_NEXT_TEST_GUI_HOST_H

/// 1 once the test process has a running NSApplication (installed when the test bundle loads, on the main thread's
/// first run-loop turn); 0 before or when it is not a GUI test run.
int cmux_next_test_gui_host_running(void);

#endif
