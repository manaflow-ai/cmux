#include "RendererMachBridge.h"

#include <servers/bootstrap.h>
#include <stdlib.h>
#include <string.h>

enum { CMUX_RENDERER_SURFACE_MESSAGE_ID = 0x43525031 };

struct cmux_renderer_port_receiver {
    mach_port_t port;
};

struct cmux_renderer_port_sender {
    mach_port_t port;
};

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface;
    uint64_t token;
} cmux_renderer_surface_message_t;

typedef struct {
    cmux_renderer_surface_message_t message;
    mach_msg_max_trailer_t trailer;
} cmux_renderer_surface_receive_buffer_t;

cmux_renderer_port_receiver_t cmux_renderer_port_receiver_create(
    const char *service_name,
    kern_return_t *error_out
) {
    cmux_renderer_port_receiver_t receiver = calloc(1, sizeof(*receiver));
    if (receiver == NULL) {
        if (error_out != NULL) *error_out = KERN_RESOURCE_SHORTAGE;
        return NULL;
    }
    kern_return_t result = mach_port_allocate(
        mach_task_self(),
        MACH_PORT_RIGHT_RECEIVE,
        &receiver->port
    );
    if (result == KERN_SUCCESS) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        result = bootstrap_register(bootstrap_port, (char *)service_name, receiver->port);
#pragma clang diagnostic pop
    }
    if (result != KERN_SUCCESS) {
        if (receiver->port != MACH_PORT_NULL) {
            mach_port_mod_refs(
                mach_task_self(),
                receiver->port,
                MACH_PORT_RIGHT_RECEIVE,
                -1
            );
        }
        free(receiver);
        if (error_out != NULL) *error_out = result;
        return NULL;
    }
    if (error_out != NULL) *error_out = KERN_SUCCESS;
    return receiver;
}

kern_return_t cmux_renderer_port_receiver_receive(
    cmux_renderer_port_receiver_t receiver,
    uint64_t *token_out,
    mach_port_t *surface_port_out
) {
    if (receiver == NULL || token_out == NULL || surface_port_out == NULL) {
        return KERN_INVALID_ARGUMENT;
    }
    cmux_renderer_surface_receive_buffer_t buffer;
    memset(&buffer, 0, sizeof(buffer));
    mach_port_t receive_port = receiver->port;
    if (receive_port == MACH_PORT_NULL) return MACH_RCV_PORT_DIED;
    kern_return_t result = mach_msg(
        &buffer.message.header,
        MACH_RCV_MSG,
        0,
        sizeof(buffer),
        receive_port,
        MACH_MSG_TIMEOUT_NONE,
        MACH_PORT_NULL
    );
    if (result != KERN_SUCCESS) return result;
    cmux_renderer_surface_message_t *message = &buffer.message;
    if (message->header.msgh_id != CMUX_RENDERER_SURFACE_MESSAGE_ID ||
        !(message->header.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
        message->body.msgh_descriptor_count != 1 ||
        message->surface.type != MACH_MSG_PORT_DESCRIPTOR) {
        return KERN_INVALID_VALUE;
    }
    *token_out = message->token;
    *surface_port_out = message->surface.name;
    return KERN_SUCCESS;
}

void cmux_renderer_port_receiver_close(cmux_renderer_port_receiver_t receiver) {
    if (receiver == NULL) return;
    mach_port_t port = receiver->port;
    receiver->port = MACH_PORT_NULL;
    if (port != MACH_PORT_NULL) {
        mach_port_mod_refs(
            mach_task_self(),
            port,
            MACH_PORT_RIGHT_RECEIVE,
            -1
        );
    }
}

void cmux_renderer_port_receiver_destroy(cmux_renderer_port_receiver_t receiver) {
    if (receiver == NULL) return;
    cmux_renderer_port_receiver_close(receiver);
    free(receiver);
}

cmux_renderer_port_sender_t cmux_renderer_port_sender_create(
    const char *service_name,
    kern_return_t *error_out
) {
    cmux_renderer_port_sender_t sender = calloc(1, sizeof(*sender));
    if (sender == NULL) {
        if (error_out != NULL) *error_out = KERN_RESOURCE_SHORTAGE;
        return NULL;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    kern_return_t result = bootstrap_look_up(
        bootstrap_port,
        (char *)service_name,
        &sender->port
    );
#pragma clang diagnostic pop
    if (result != KERN_SUCCESS) {
        free(sender);
        if (error_out != NULL) *error_out = result;
        return NULL;
    }
    if (error_out != NULL) *error_out = KERN_SUCCESS;
    return sender;
}

kern_return_t cmux_renderer_port_sender_send(
    cmux_renderer_port_sender_t sender,
    uint64_t token,
    mach_port_t surface_port
) {
    if (sender == NULL || surface_port == MACH_PORT_NULL) {
        return KERN_INVALID_ARGUMENT;
    }
    cmux_renderer_surface_message_t message;
    memset(&message, 0, sizeof(message));
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) |
        MACH_MSGH_BITS_COMPLEX;
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = sender->port;
    message.header.msgh_local_port = MACH_PORT_NULL;
    message.header.msgh_id = CMUX_RENDERER_SURFACE_MESSAGE_ID;
    message.body.msgh_descriptor_count = 1;
    message.surface.name = surface_port;
    message.surface.disposition = MACH_MSG_TYPE_MOVE_SEND;
    message.surface.type = MACH_MSG_PORT_DESCRIPTOR;
    message.token = token;
    kern_return_t result = mach_msg(
        &message.header,
        MACH_SEND_MSG,
        message.header.msgh_size,
        0,
        MACH_PORT_NULL,
        MACH_MSG_TIMEOUT_NONE,
        MACH_PORT_NULL
    );
    if (result != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), surface_port);
    }
    return result;
}

void cmux_renderer_port_sender_destroy(cmux_renderer_port_sender_t sender) {
    if (sender == NULL) return;
    if (sender->port != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), sender->port);
    }
    free(sender);
}
