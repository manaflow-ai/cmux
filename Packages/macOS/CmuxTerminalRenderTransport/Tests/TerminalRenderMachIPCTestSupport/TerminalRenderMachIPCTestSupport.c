#include "TerminalRenderMachIPCTestSupport.h"

#include <servers/bootstrap.h>
#include <string.h>

enum {
    CMUX_TERMINAL_RENDER_TEST_OVERSIZED_PAYLOAD_LENGTH = 4096,
};

typedef struct {
    mach_msg_header_t header;
    uint8_t payload[CMUX_TERMINAL_RENDER_TEST_OVERSIZED_PAYLOAD_LENGTH];
} cmux_terminal_render_test_oversized_message_s;

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t unexpected_port;
    uint32_t marker;
} cmux_terminal_render_test_unexpected_complex_message_s;

static kern_return_t cmux_terminal_render_test_lookup_sender(
    const char *service_name,
    mach_port_t *sender
) {
    if (service_name == NULL || sender == NULL) {
        return KERN_INVALID_ARGUMENT;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    kern_return_t result = bootstrap_look_up(
        bootstrap_port,
        service_name,
        sender
    );
#pragma clang diagnostic pop
    return result;
}

kern_return_t cmux_terminal_render_test_send_oversized_message(
    const char *service_name
) {
    mach_port_t sender = MACH_PORT_NULL;
    kern_return_t result = cmux_terminal_render_test_lookup_sender(
        service_name,
        &sender
    );
    if (result != KERN_SUCCESS) {
        return result;
    }

    cmux_terminal_render_test_oversized_message_s message;
    memset(&message, 0, sizeof(message));
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_size = (mach_msg_size_t)sizeof(message);
    message.header.msgh_remote_port = sender;
    message.header.msgh_local_port = MACH_PORT_NULL;
    message.header.msgh_id = 0x434D5846;

    result = mach_msg(
        &message.header,
        MACH_SEND_MSG | MACH_SEND_TIMEOUT,
        message.header.msgh_size,
        0,
        MACH_PORT_NULL,
        0,
        MACH_PORT_NULL
    );
    mach_port_deallocate(mach_task_self(), sender);
    return result;
}

kern_return_t cmux_terminal_render_test_send_unexpected_complex_message(
    const char *service_name
) {
    mach_port_t sender = MACH_PORT_NULL;
    kern_return_t result = cmux_terminal_render_test_lookup_sender(
        service_name,
        &sender
    );
    if (result != KERN_SUCCESS) {
        return result;
    }

    cmux_terminal_render_test_unexpected_complex_message_s message;
    memset(&message, 0, sizeof(message));
    message.header.msgh_bits = MACH_MSGH_BITS_COMPLEX |
        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_size = (mach_msg_size_t)sizeof(message);
    message.header.msgh_remote_port = sender;
    message.header.msgh_local_port = MACH_PORT_NULL;
    message.header.msgh_id = 0x434D5846;
    message.body.msgh_descriptor_count = 1;
    message.unexpected_port.name = sender;
    message.unexpected_port.disposition = MACH_MSG_TYPE_COPY_SEND;
    message.unexpected_port.type = MACH_MSG_PORT_DESCRIPTOR;
    message.marker = 0xBADCAFE;

    result = mach_msg(
        &message.header,
        MACH_SEND_MSG | MACH_SEND_TIMEOUT,
        message.header.msgh_size,
        0,
        MACH_PORT_NULL,
        0,
        MACH_PORT_NULL
    );
    mach_port_deallocate(mach_task_self(), sender);
    return result;
}
