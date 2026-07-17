#ifndef CMUX_TERMINAL_RENDER_MACH_IPC_TEST_SUPPORT_H
#define CMUX_TERMINAL_RENDER_MACH_IPC_TEST_SUPPORT_H

#include <mach/mach.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Enqueues a simple Mach message larger than the production receive buffer.
kern_return_t cmux_terminal_render_test_send_oversized_message(
    const char *service_name
);

/// Enqueues a kernel-valid complex message with an unexpected protocol shape.
kern_return_t cmux_terminal_render_test_send_unexpected_complex_message(
    const char *service_name
);

#ifdef __cplusplus
}
#endif

#endif
