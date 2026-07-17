#ifndef RENDERER_MACH_BRIDGE_H
#define RENDERER_MACH_BRIDGE_H

#include <mach/mach.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cmux_renderer_port_receiver *cmux_renderer_port_receiver_t;
typedef struct cmux_renderer_port_sender *cmux_renderer_port_sender_t;

cmux_renderer_port_receiver_t cmux_renderer_port_receiver_create(
    const char *service_name,
    kern_return_t *error_out
);
kern_return_t cmux_renderer_port_receiver_receive(
    cmux_renderer_port_receiver_t receiver,
    uint64_t *token_out,
    mach_port_t *surface_port_out
);
void cmux_renderer_port_receiver_close(cmux_renderer_port_receiver_t receiver);
void cmux_renderer_port_receiver_destroy(cmux_renderer_port_receiver_t receiver);

cmux_renderer_port_sender_t cmux_renderer_port_sender_create(
    const char *service_name,
    kern_return_t *error_out
);
kern_return_t cmux_renderer_port_sender_send(
    cmux_renderer_port_sender_t sender,
    uint64_t token,
    mach_port_t surface_port
);
void cmux_renderer_port_sender_destroy(cmux_renderer_port_sender_t sender);

#ifdef __cplusplus
}
#endif

#endif
