import GhosttyKit

/// Carrier for the "View as Text" sheet's surface pointer across the hop to the
/// current surface generation executor.
///
/// Safety: the pointer is only dereferenced on the queue that owns
/// `process_output` and is FIFO-ordered before any queued free.
struct CopyableTextSurfaceHandle: @unchecked Sendable {
    let surface: ghostty_surface_t
}
