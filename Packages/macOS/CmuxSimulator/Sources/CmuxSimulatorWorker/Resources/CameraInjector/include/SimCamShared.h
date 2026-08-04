// Adapted from serve-sim commit af681b8c3b0453f31dcb8e98a3389f23b7cfc6b0 (Apache-2.0).
// Modified by cmux for native worker integration.
//
// Wire format for serve-sim's simulator camera feed.
//
// Frames travel over a private POSIX shared-memory ring whose unguessable name
// is passed only to the injected process. Camera pixels never enter the global
// IOSurface namespace.
//
// A tiny POSIX shared-memory region acts as the control channel: it carries
// which slot holds the newest frame, the frame sequence number, and the mirror
// mode. BGRA pixel slots follow the control structures in the same region.
//
// Frames are tightly packed BGRA. `bytesPerRow` is width*4.
//
// Synchronization is lock-free and lossy. The writer renders into the next
// slot, points `latestIndex` at it, then bumps `frameSeq` last. The reader
// samples `frameSeq` before and after copying the slot and retries on the next
// tick if they disagree. A single dropped frame is fine for a 30 fps camera.

#ifndef SIM_CAM_SHARED_H
#define SIM_CAM_SHARED_H

#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

#define SIMCAM_SHM_MAGIC      0x53434D31u  // 'SCM1'
#define SIMCAM_PIXEL_BGRA     0u
#define SIMCAM_DEFAULT_WIDTH  1280u
#define SIMCAM_DEFAULT_HEIGHT 720u

// Number of private pixel slots in the ring.
#define SIMCAM_SURFACE_RING   4u
#define SIMCAM_ATTACHMENT_SLOTS 16u

// Mirror mode codes for SimCamShmHeader.mirrorMode.
// "Unset" lets the dylib fall back to its env-var configuration (back-compat
// with hosts that don't write the byte).
#define SIMCAM_MIRROR_UNSET   0xFF
#define SIMCAM_MIRROR_AUTO    0
#define SIMCAM_MIRROR_ON      1
#define SIMCAM_MIRROR_OFF     2

// Control header is 64 bytes. The surface-ID table follows immediately after.
typedef struct {
    uint32_t magic;        // SIMCAM_SHM_MAGIC
    uint32_t version;      // bumps on layout change
    uint32_t width;
    uint32_t height;
    uint32_t pixelFormat;  // SIMCAM_PIXEL_BGRA
    uint32_t bytesPerRow;
    uint64_t pixelByteSize;// logical frame size: width*height*4
    _Atomic uint64_t frameSeq; // written LAST with release; readers acquire-load
    uint64_t timestampNs;  // mach_absolute_time-based, host monotonic
    uint8_t  mirrorMode;   // SIMCAM_MIRROR_*; UNSET = ignore (use env)
    uint8_t  reserved[15];
} SimCamShmHeader;

_Static_assert(sizeof(SimCamShmHeader) == 64, "SimCamShmHeader must be 64 bytes");
_Static_assert(offsetof(SimCamShmHeader, frameSeq) == 32, "frameSeq offset must stay stable");
_Static_assert(offsetof(SimCamShmHeader, mirrorMode) == 48, "mirrorMode offset must stay stable");

typedef struct {
    _Atomic uint32_t pid;
    uint32_t reserved;
    _Atomic uint64_t heartbeatNs;
} SimCamAttachmentSlot;

typedef struct {
    SimCamAttachmentSlot slots[SIMCAM_ATTACHMENT_SLOTS];
} SimCamAttachmentTable;

// Pixel-ring metadata. `latestIndex` is updated before frameSeq.
typedef struct __attribute__((packed)) {
    uint32_t frameCount;
    uint32_t latestIndex;
} SimCamFrameTable;

// Total control-region size: header + surface table.
static inline uint64_t SimCamControlSize(void) {
    return (uint64_t)sizeof(SimCamShmHeader)
        + (uint64_t)sizeof(SimCamAttachmentTable)
        + (uint64_t)sizeof(SimCamFrameTable);
}

static inline uint64_t SimCamSharedSize(uint32_t bytesPerRow, uint32_t height) {
    return SimCamControlSize()
        + (uint64_t)bytesPerRow * (uint64_t)height * SIMCAM_SURFACE_RING;
}

#endif
