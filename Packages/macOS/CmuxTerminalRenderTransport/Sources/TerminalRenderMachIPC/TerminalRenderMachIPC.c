#include "TerminalRenderMachIPC.h"

#include <IOSurface/IOSurface.h>
#include <bsm/libbsm.h>
#include <servers/bootstrap.h>
#include <stdbool.h>
#include <string.h>

enum {
    CMUX_TERMINAL_RENDER_FRAME_MESSAGE_ID = 0x434D5846,
};

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface_port;
    uint8_t capability[CMUX_TERMINAL_RENDER_CAPABILITY_LENGTH];
    uint8_t metadata[CMUX_TERMINAL_RENDER_METADATA_LENGTH];
} cmux_terminal_render_frame_message_s;

typedef union {
    cmux_terminal_render_frame_message_s message;
    uint8_t bytes[
        sizeof(cmux_terminal_render_frame_message_s) +
        sizeof(mach_msg_max_trailer_t)
    ];
} cmux_terminal_render_frame_receive_buffer_u;

static bool cmux_terminal_render_constant_time_equal(
    const uint8_t *left,
    const uint8_t *right,
    size_t count
) {
    volatile uint8_t difference = 0;
    for (size_t index = 0; index < count; index += 1) {
        difference |= left[index] ^ right[index];
    }
    return difference == 0;
}

static void cmux_terminal_render_release_message_surface(
    cmux_terminal_render_frame_message_s *message
) {
    if (message->body.msgh_descriptor_count == 1 &&
        message->surface_port.type == MACH_MSG_PORT_DESCRIPTOR &&
        MACH_PORT_VALID(message->surface_port.name)) {
        mach_port_deallocate(mach_task_self(), message->surface_port.name);
        message->surface_port.name = MACH_PORT_NULL;
    }
}

cmux_terminal_render_status_t cmux_terminal_render_receiver_create(
    const char *service_name,
    uint32_t queue_limit,
    mach_port_t *receiver,
    kern_return_t *mach_error
) {
    if (mach_error != NULL) {
        *mach_error = KERN_SUCCESS;
    }
    if (service_name == NULL || receiver == NULL || mach_error == NULL ||
        queue_limit == 0 ||
        queue_limit > CMUX_TERMINAL_RENDER_MAXIMUM_QUEUE_LIMIT) {
        return CMUX_TERMINAL_RENDER_STATUS_INVALID_ARGUMENT;
    }

    mach_port_t port = MACH_PORT_NULL;
    kern_return_t result = mach_port_allocate(
        mach_task_self(),
        MACH_PORT_RIGHT_RECEIVE,
        &port
    );
    if (result != KERN_SUCCESS) {
        *mach_error = result;
        return CMUX_TERMINAL_RENDER_STATUS_PORT_FAILURE;
    }

    mach_port_limits_t limits = {
        .mpl_qlimit = (mach_port_msgcount_t)queue_limit,
    };
    result = mach_port_set_attributes(
        mach_task_self(),
        port,
        MACH_PORT_LIMITS_INFO,
        (mach_port_info_t)&limits,
        MACH_PORT_LIMITS_INFO_COUNT
    );
    if (result != KERN_SUCCESS) {
        *mach_error = result;
        mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
        return CMUX_TERMINAL_RENDER_STATUS_PORT_FAILURE;
    }

    result = mach_port_insert_right(
        mach_task_self(),
        port,
        port,
        MACH_MSG_TYPE_MAKE_SEND
    );
    if (result != KERN_SUCCESS) {
        *mach_error = result;
        mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
        return CMUX_TERMINAL_RENDER_STATUS_PORT_FAILURE;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    result = bootstrap_register(bootstrap_port, (char *)service_name, port);
#pragma clang diagnostic pop
    if (result != KERN_SUCCESS) {
        *mach_error = result;
        mach_port_destruct(mach_task_self(), port, -1, 0);
        return CMUX_TERMINAL_RENDER_STATUS_BOOTSTRAP_FAILURE;
    }

    *receiver = port;
    return CMUX_TERMINAL_RENDER_STATUS_SUCCESS;
}

void cmux_terminal_render_receiver_destroy(mach_port_t receiver) {
    if (MACH_PORT_VALID(receiver)) {
        mach_port_destruct(mach_task_self(), receiver, -1, 0);
    }
}

cmux_terminal_render_status_t cmux_terminal_render_sender_connect(
    const char *service_name,
    mach_port_t *sender,
    kern_return_t *mach_error
) {
    if (mach_error != NULL) {
        *mach_error = KERN_SUCCESS;
    }
    if (service_name == NULL || sender == NULL || mach_error == NULL) {
        return CMUX_TERMINAL_RENDER_STATUS_INVALID_ARGUMENT;
    }
    kern_return_t result = bootstrap_look_up(bootstrap_port, service_name, sender);
    if (result != KERN_SUCCESS) {
        *mach_error = result;
        return CMUX_TERMINAL_RENDER_STATUS_BOOTSTRAP_FAILURE;
    }
    return CMUX_TERMINAL_RENDER_STATUS_SUCCESS;
}

void cmux_terminal_render_sender_destroy(mach_port_t sender) {
    if (MACH_PORT_VALID(sender)) {
        mach_port_deallocate(mach_task_self(), sender);
    }
}

cmux_terminal_render_status_t cmux_terminal_render_frame_send(
    mach_port_t sender,
    IOSurfaceRef surface,
    const uint8_t *capability,
    const uint8_t *metadata,
    kern_return_t *mach_error
) {
    if (mach_error != NULL) {
        *mach_error = KERN_SUCCESS;
    }
    if (!MACH_PORT_VALID(sender) || surface == NULL || capability == NULL ||
        metadata == NULL || mach_error == NULL) {
        return CMUX_TERMINAL_RENDER_STATUS_INVALID_ARGUMENT;
    }

    mach_port_t surface_port = IOSurfaceCreateMachPort(surface);
    if (!MACH_PORT_VALID(surface_port)) {
        return CMUX_TERMINAL_RENDER_STATUS_SURFACE_IMPORT_FAILURE;
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
    memcpy(message.capability, capability, sizeof(message.capability));
    memcpy(message.metadata, metadata, sizeof(message.metadata));

    kern_return_t result = mach_msg(
        &message.header,
        MACH_SEND_MSG | MACH_SEND_TIMEOUT,
        message.header.msgh_size,
        0,
        MACH_PORT_NULL,
        0,
        MACH_PORT_NULL
    );
    if (result == MACH_SEND_TIMED_OUT) {
        mach_port_deallocate(mach_task_self(), surface_port);
        return CMUX_TERMINAL_RENDER_STATUS_QUEUE_FULL;
    }
    if (result != KERN_SUCCESS) {
        *mach_error = result;
        mach_port_deallocate(mach_task_self(), surface_port);
        return CMUX_TERMINAL_RENDER_STATUS_SEND_FAILURE;
    }
    return CMUX_TERMINAL_RENDER_STATUS_SUCCESS;
}

static cmux_terminal_render_status_t cmux_terminal_render_frame_receive_impl(
    mach_port_t receiver,
    uint32_t timeout_ms,
    const uint8_t *expected_capability,
    pid_t expected_pid,
    uid_t expected_euid,
    bool require_expected_peer,
    cmux_terminal_render_received_frame_s *received_frame,
    kern_return_t *mach_error
) {
    if (mach_error != NULL) {
        *mach_error = KERN_SUCCESS;
    }
    if (!MACH_PORT_VALID(receiver) || expected_capability == NULL ||
        (require_expected_peer && expected_pid <= 0) ||
        received_frame == NULL || mach_error == NULL) {
        return CMUX_TERMINAL_RENDER_STATUS_INVALID_ARGUMENT;
    }
    memset(received_frame, 0, sizeof(*received_frame));

    cmux_terminal_render_frame_receive_buffer_u buffer;
    memset(&buffer, 0, sizeof(buffer));
    cmux_terminal_render_frame_message_s *message = &buffer.message;
    message->header.msgh_local_port = receiver;
    message->header.msgh_size = (mach_msg_size_t)sizeof(buffer);

    mach_msg_option_t options = MACH_RCV_MSG | MACH_RCV_TIMEOUT |
        MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
        MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
    kern_return_t result = mach_msg(
        &message->header,
        options,
        0,
        (mach_msg_size_t)sizeof(buffer),
        receiver,
        timeout_ms,
        MACH_PORT_NULL
    );
    if (result == MACH_RCV_TIMED_OUT) {
        return CMUX_TERMINAL_RENDER_STATUS_TIMED_OUT;
    }
    if (result == MACH_RCV_TOO_LARGE) {
        /*
         * Deliberately omit MACH_RCV_LARGE. XNU therefore dequeues the
         * oversized message and destroys its carried rights before returning
         * MACH_RCV_TOO_LARGE, so this is a consumed malformed frame rather
         * than a wedged queue or transport failure.
         */
        return CMUX_TERMINAL_RENDER_STATUS_INVALID_MESSAGE;
    }
    if (result != KERN_SUCCESS) {
        *mach_error = result;
        return CMUX_TERMINAL_RENDER_STATUS_RECEIVE_FAILURE;
    }

    bool message_is_valid =
        message->header.msgh_id == CMUX_TERMINAL_RENDER_FRAME_MESSAGE_ID &&
        message->header.msgh_size == sizeof(*message) &&
        (message->header.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0 &&
        message->body.msgh_descriptor_count == 1 &&
        message->surface_port.type == MACH_MSG_PORT_DESCRIPTOR &&
        MACH_PORT_VALID(message->surface_port.name);
    if (!message_is_valid) {
        /*
         * A successful mach_msg receive contains a kernel-validated complex
         * descriptor layout. mach_msg_destroy is the receiver-side operation
         * for releasing rights in a valid Mach message whose protocol shape
         * this service does not accept.
         */
        mach_msg_destroy(&message->header);
        return CMUX_TERMINAL_RENDER_STATUS_INVALID_MESSAGE;
    }

    uint8_t *trailer_address = buffer.bytes + round_msg(message->header.msgh_size);
    uint8_t *buffer_end = buffer.bytes + sizeof(buffer.bytes);
    if (trailer_address > buffer_end - sizeof(mach_msg_audit_trailer_t)) {
        cmux_terminal_render_release_message_surface(message);
        return CMUX_TERMINAL_RENDER_STATUS_INVALID_MESSAGE;
    }
    mach_msg_audit_trailer_t *trailer =
        (mach_msg_audit_trailer_t *)(void *)trailer_address;
    if (trailer->msgh_trailer_type != MACH_MSG_TRAILER_FORMAT_0 ||
        trailer->msgh_trailer_size < sizeof(mach_msg_audit_trailer_t)) {
        cmux_terminal_render_release_message_surface(message);
        return CMUX_TERMINAL_RENDER_STATUS_INVALID_MESSAGE;
    }

    pid_t sender_pid = audit_token_to_pid(trailer->msgh_audit);
    uid_t sender_euid = audit_token_to_euid(trailer->msgh_audit);
    if (require_expected_peer &&
        (sender_pid != expected_pid || sender_euid != expected_euid)) {
        cmux_terminal_render_release_message_surface(message);
        return CMUX_TERMINAL_RENDER_STATUS_PEER_MISMATCH;
    }
    if (!cmux_terminal_render_constant_time_equal(
            message->capability,
            expected_capability,
            CMUX_TERMINAL_RENDER_CAPABILITY_LENGTH
        )) {
        cmux_terminal_render_release_message_surface(message);
        return CMUX_TERMINAL_RENDER_STATUS_CAPABILITY_MISMATCH;
    }

    memcpy(received_frame->metadata, message->metadata, sizeof(received_frame->metadata));
    received_frame->surface_port = message->surface_port.name;
    received_frame->sender_pid = sender_pid;
    received_frame->sender_euid = sender_euid;
    message->surface_port.name = MACH_PORT_NULL;
    return CMUX_TERMINAL_RENDER_STATUS_SUCCESS;
}

cmux_terminal_render_status_t cmux_terminal_render_frame_receive(
    mach_port_t receiver,
    uint32_t timeout_ms,
    const uint8_t *expected_capability,
    pid_t expected_pid,
    uid_t expected_euid,
    cmux_terminal_render_received_frame_s *received_frame,
    kern_return_t *mach_error
) {
    return cmux_terminal_render_frame_receive_impl(
        receiver,
        timeout_ms,
        expected_capability,
        expected_pid,
        expected_euid,
        true,
        received_frame,
        mach_error
    );
}

cmux_terminal_render_status_t cmux_terminal_render_frame_receive_quiesced(
    mach_port_t receiver,
    const uint8_t *expected_capability,
    cmux_terminal_render_received_frame_s *received_frame,
    kern_return_t *mach_error
) {
    return cmux_terminal_render_frame_receive_impl(
        receiver,
        0,
        expected_capability,
        0,
        0,
        false,
        received_frame,
        mach_error
    );
}

void cmux_terminal_render_surface_right_release(mach_port_t surface_port) {
    if (MACH_PORT_VALID(surface_port)) {
        mach_port_deallocate(mach_task_self(), surface_port);
    }
}

IOSurfaceRef cmux_terminal_render_surface_right_import(mach_port_t surface_port) {
    if (!MACH_PORT_VALID(surface_port)) {
        return NULL;
    }
    IOSurfaceRef surface = IOSurfaceLookupFromMachPort(surface_port);
    mach_port_deallocate(mach_task_self(), surface_port);
    return surface;
}
