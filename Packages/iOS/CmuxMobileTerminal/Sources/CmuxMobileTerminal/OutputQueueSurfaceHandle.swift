import GhosttyKit

/// Carries a live libghostty surface pointer across hops to
/// ``GhosttySurfaceView/outputQueue``.
///
/// The pointer is dereferenced only on the queue that owns
/// `process_output`/`render_now`/`binding_action`. Queued frees use the same
/// queue, so FIFO ordering keeps the pointer alive for earlier queued work.
struct OutputQueueSurfaceHandle: @unchecked Sendable {
    let surface: ghostty_surface_t
}
