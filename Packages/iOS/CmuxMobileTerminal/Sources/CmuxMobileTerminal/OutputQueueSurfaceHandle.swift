import GhosttyKit

/// Carrier for `ghostty_surface_t` across hops to `GhosttySurfaceView.outputQueue`.
///
/// The pointer is dereferenced only on the serial queue that owns Ghostty output,
/// render, binding, and free work. FIFO ordering guarantees any queued free runs
/// after already-enqueued work that captured this handle, so carrying it across
/// that queue hop is safe - hence `@unchecked Sendable`.
struct OutputQueueSurfaceHandle: @unchecked Sendable {
    let surface: ghostty_surface_t
}
