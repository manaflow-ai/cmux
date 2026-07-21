#ifndef CMUX_TERMINAL_RENDER_MACH_IPC_H
#define CMUX_TERMINAL_RENDER_MACH_IPC_H

#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

CF_ASSUME_NONNULL_BEGIN

enum {
    CMUX_TERMINAL_RENDER_TOKEN_LENGTH = 16,
    CMUX_TERMINAL_RENDER_SURFACE_ID_LENGTH = 16,
};

typedef struct {
    uint8_t authentication_token[CMUX_TERMINAL_RENDER_TOKEN_LENGTH];
    uint8_t surface_id[CMUX_TERMINAL_RENDER_SURFACE_ID_LENGTH];
    uint64_t worker_generation;
    uint64_t surface_generation;
    uint64_t frame_sequence;
    uint32_t width;
    uint32_t height;
} cmux_terminal_render_frame_metadata_s;

/// Creates a receive right and registers a random, caller-owned bootstrap name.
/// The receive right is destroyed by cmux_terminal_render_receiver_destroy.
kern_return_t cmux_terminal_render_receiver_create(
    const char *service_name,
    mach_port_t *receiver
);

/// Destroys a receive right, waking any blocked receiver.
void cmux_terminal_render_receiver_destroy(mach_port_t receiver);

/// Looks up the host's registered frame endpoint from the worker process.
kern_return_t cmux_terminal_render_sender_connect(
    const char *service_name,
    mach_port_t *sender
);

/// Releases a sender right returned by cmux_terminal_render_sender_connect.
void cmux_terminal_render_sender_destroy(mach_port_t sender);

/// Transfers a secure IOSurface Mach port with bounded, nonblocking delivery.
/// Returns KERN_SUCCESS when the frame was accepted. A full host queue returns
/// MACH_SEND_TIMED_OUT so the renderer can drop the stale frame without waiting.
kern_return_t cmux_terminal_render_frame_send(
    mach_port_t sender,
    IOSurfaceRef surface,
    const cmux_terminal_render_frame_metadata_s *metadata
);

/// Receives one frame and recreates its IOSurface in the host task.
/// The returned IOSurface follows the Create Rule. MACH_RCV_TIMED_OUT is a
/// normal idle result. Invalid/authentication-mismatched messages are reported
/// as MIG_TYPE_ERROR and their transferred rights are released.
kern_return_t cmux_terminal_render_frame_receive(
    mach_port_t receiver,
    uint32_t timeout_ms,
    const uint8_t * _Nonnull expected_authentication_token,
    cmux_terminal_render_frame_metadata_s *metadata,
    IOSurfaceRef _Nullable * _Nonnull surface
);

CF_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif

#endif
