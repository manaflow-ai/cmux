#include "TerminalRenderMachIPC.h"

#include <IOSurface/IOSurface.h>
#include <servers/bootstrap.h>
#include <string.h>

enum {
    CMUX_TERMINAL_RENDER_FRAME_MESSAGE_ID = 0x434D5852,
};

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface_port;
    cmux_terminal_render_frame_metadata_s metadata;
} cmux_terminal_render_frame_message_s;

typedef union {
    cmux_terminal_render_frame_message_s message;
    uint8_t bytes[
        sizeof(cmux_terminal_render_frame_message_s) +
        sizeof(mach_msg_max_trailer_t)
    ];
} cmux_terminal_render_frame_receive_buffer_u;

kern_return_t cmux_terminal_render_receiver_create(
    const char *service_name,
    mach_port_t *receiver
) {
    if (service_name == NULL || receiver == NULL) {
        return KERN_INVALID_ARGUMENT;
    }

    mach_port_t port = MACH_PORT_NULL;
    kern_return_t result = mach_port_allocate(
        mach_task_self(),
        MACH_PORT_RIGHT_RECEIVE,
        &port
    );
    if (result != KERN_SUCCESS) {
        return result;
    }

    result = mach_port_insert_right(
        mach_task_self(),
        port,
        port,
        MACH_MSG_TYPE_MAKE_SEND
    );
    if (result != KERN_SUCCESS) {
        mach_port_destruct(mach_task_self(), port, 0, 0);
        return result;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    result = bootstrap_register(bootstrap_port, (char *)service_name, port);
#pragma clang diagnostic pop
    if (result != KERN_SUCCESS) {
        mach_port_destruct(mach_task_self(), port, -1, 0);
        return result;
    }

    *receiver = port;
    return KERN_SUCCESS;
}

void cmux_terminal_render_receiver_destroy(mach_port_t receiver) {
    if (MACH_PORT_VALID(receiver)) {
        mach_port_destruct(mach_task_self(), receiver, -1, 0);
    }
}

kern_return_t cmux_terminal_render_sender_connect(
    const char *service_name,
    mach_port_t *sender
) {
    if (service_name == NULL || sender == NULL) {
        return KERN_INVALID_ARGUMENT;
    }
    return bootstrap_look_up(bootstrap_port, service_name, sender);
}

void cmux_terminal_render_sender_destroy(mach_port_t sender) {
    if (MACH_PORT_VALID(sender)) {
        mach_port_deallocate(mach_task_self(), sender);
    }
}

kern_return_t cmux_terminal_render_frame_send(
    mach_port_t sender,
    IOSurfaceRef surface,
    const cmux_terminal_render_frame_metadata_s *metadata
) {
    if (!MACH_PORT_VALID(sender) || surface == NULL || metadata == NULL) {
        return KERN_INVALID_ARGUMENT;
    }

    mach_port_t surface_port = IOSurfaceCreateMachPort(surface);
    if (!MACH_PORT_VALID(surface_port)) {
        return KERN_FAILURE;
    }

    cmux_terminal_render_frame_message_s message;
    memset(&message, 0, sizeof(message));
    message.header.msgh_bits = MACH_MSGH_BITS_COMPLEX |
        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_size = (mach_msg_size_t)sizeof(message);
    message.header.msgh_remote_port = sender;
    message.header.msgh_local_port = MACH_PORT_NULL;
    message.header.msgh_id = CMUX_TERMINAL_RENDER_FRAME_MESSAGE_ID;
    message.body.msgh_descriptor_count = 1;
    message.surface_port.name = surface_port;
    message.surface_port.disposition = MACH_MSG_TYPE_MOVE_SEND;
    message.surface_port.type = MACH_MSG_PORT_DESCRIPTOR;
    message.metadata = *metadata;

    kern_return_t result = mach_msg(
        &message.header,
        MACH_SEND_MSG | MACH_SEND_TIMEOUT,
        message.header.msgh_size,
        0,
        MACH_PORT_NULL,
        0,
        MACH_PORT_NULL
    );
    if (result != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), surface_port);
    }
    return result;
}

kern_return_t cmux_terminal_render_frame_receive(
    mach_port_t receiver,
    uint32_t timeout_ms,
    const uint8_t expected_authentication_token[CMUX_TERMINAL_RENDER_TOKEN_LENGTH],
    cmux_terminal_render_frame_metadata_s *metadata,
    IOSurfaceRef *surface
) {
    if (!MACH_PORT_VALID(receiver) || expected_authentication_token == NULL ||
        metadata == NULL || surface == NULL) {
        return KERN_INVALID_ARGUMENT;
    }
    *surface = NULL;

    cmux_terminal_render_frame_receive_buffer_u buffer;
    memset(&buffer, 0, sizeof(buffer));
    cmux_terminal_render_frame_message_s *message = &buffer.message;
    message->header.msgh_local_port = receiver;
    message->header.msgh_size = (mach_msg_size_t)sizeof(buffer);

    kern_return_t result = mach_msg(
        &message->header,
        MACH_RCV_MSG | MACH_RCV_TIMEOUT,
        0,
        (mach_msg_size_t)sizeof(buffer),
        receiver,
        timeout_ms,
        MACH_PORT_NULL
    );
    if (result != KERN_SUCCESS) {
        return result;
    }

    bool valid = message->header.msgh_id == CMUX_TERMINAL_RENDER_FRAME_MESSAGE_ID &&
        (message->header.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0 &&
        message->body.msgh_descriptor_count == 1 &&
        message->surface_port.type == MACH_MSG_PORT_DESCRIPTOR &&
        MACH_PORT_VALID(message->surface_port.name) &&
        memcmp(
            message->metadata.authentication_token,
            expected_authentication_token,
            CMUX_TERMINAL_RENDER_TOKEN_LENGTH
        ) == 0;
    if (!valid) {
        if (message->body.msgh_descriptor_count == 1 &&
            message->surface_port.type == MACH_MSG_PORT_DESCRIPTOR &&
            MACH_PORT_VALID(message->surface_port.name)) {
            mach_port_deallocate(mach_task_self(), message->surface_port.name);
        }
        return MIG_TYPE_ERROR;
    }

    IOSurfaceRef received_surface = IOSurfaceLookupFromMachPort(
        message->surface_port.name
    );
    mach_port_deallocate(mach_task_self(), message->surface_port.name);
    if (received_surface == NULL) {
        return KERN_FAILURE;
    }

    *metadata = message->metadata;
    *surface = received_surface;
    return KERN_SUCCESS;
}
