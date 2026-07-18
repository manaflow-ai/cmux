#ifndef CMUX_TERMINAL_RENDER_MACH_IPC_H
#define CMUX_TERMINAL_RENDER_MACH_IPC_H

#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

CF_ASSUME_NONNULL_BEGIN

enum {
    CMUX_TERMINAL_RENDER_CAPABILITY_LENGTH = 32,
    CMUX_TERMINAL_RENDER_METADATA_LENGTH = 160,
    CMUX_TERMINAL_RENDER_MAXIMUM_QUEUE_LIMIT = 64,
};

typedef enum : int32_t {
    CMUX_TERMINAL_RENDER_STATUS_SUCCESS = 0,
    CMUX_TERMINAL_RENDER_STATUS_TIMED_OUT = 1,
    CMUX_TERMINAL_RENDER_STATUS_QUEUE_FULL = 2,
    CMUX_TERMINAL_RENDER_STATUS_INVALID_ARGUMENT = 3,
    CMUX_TERMINAL_RENDER_STATUS_INVALID_MESSAGE = 4,
    CMUX_TERMINAL_RENDER_STATUS_CAPABILITY_MISMATCH = 5,
    CMUX_TERMINAL_RENDER_STATUS_PEER_MISMATCH = 6,
    CMUX_TERMINAL_RENDER_STATUS_PORT_FAILURE = 7,
    CMUX_TERMINAL_RENDER_STATUS_BOOTSTRAP_FAILURE = 8,
    CMUX_TERMINAL_RENDER_STATUS_SEND_FAILURE = 9,
    CMUX_TERMINAL_RENDER_STATUS_RECEIVE_FAILURE = 10,
    CMUX_TERMINAL_RENDER_STATUS_SURFACE_IMPORT_FAILURE = 11,
} cmux_terminal_render_status_t;

typedef struct {
    uint8_t metadata[CMUX_TERMINAL_RENDER_METADATA_LENGTH];
    mach_port_t surface_port;
    pid_t sender_pid;
    uid_t sender_euid;
} cmux_terminal_render_received_frame_s;

/// Creates a bounded Mach receive right and registers its send right.
cmux_terminal_render_status_t cmux_terminal_render_receiver_create(
    const char *service_name,
    uint32_t queue_limit,
    mach_port_t *receiver,
    kern_return_t *mach_error
);

/// Destroys a host receive right and wakes any pending receive operation.
void cmux_terminal_render_receiver_destroy(mach_port_t receiver);

/// Resolves the receiver's send right from the worker's bootstrap namespace.
cmux_terminal_render_status_t cmux_terminal_render_sender_connect(
    const char *service_name,
    mach_port_t *sender,
    kern_return_t *mach_error
);

/// Releases a worker send right returned by the connect function.
void cmux_terminal_render_sender_destroy(mach_port_t sender);

/// Transfers one IOSurface send right without waiting for queue capacity.
cmux_terminal_render_status_t cmux_terminal_render_frame_send(
    mach_port_t sender,
    IOSurfaceRef surface,
    const uint8_t * _Nonnull capability,
    const uint8_t * _Nonnull metadata,
    kern_return_t *mach_error
);

/// Receives one frame and authenticates its kernel audit trailer and capability.
cmux_terminal_render_status_t cmux_terminal_render_frame_receive(
    mach_port_t receiver,
    uint32_t timeout_ms,
    const uint8_t * _Nonnull expected_capability,
    pid_t expected_pid,
    uid_t expected_euid,
    cmux_terminal_render_received_frame_s *received_frame,
    kern_return_t *mach_error
);

/// Receives one frame after the producer has been proved quiescent.
///
/// The endpoint capability remains mandatory, but the caller may not yet have
/// observed the producer PID/eUID when the first frame preceded its readiness
/// event. This entry point is only for draining that closed publication epoch.
cmux_terminal_render_status_t cmux_terminal_render_frame_receive_quiesced(
    mach_port_t receiver,
    const uint8_t * _Nonnull expected_capability,
    cmux_terminal_render_received_frame_s *received_frame,
    kern_return_t *mach_error
);

/// Releases an unimported IOSurface send right returned by the receive function.
void cmux_terminal_render_surface_right_release(mach_port_t surface_port);

/// Imports and consumes an IOSurface send right, returning a retained surface.
IOSurfaceRef _Nullable cmux_terminal_render_surface_right_import(
    mach_port_t surface_port
) CF_RETURNS_RETAINED;

CF_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif

#endif
