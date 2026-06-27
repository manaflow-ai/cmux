#if canImport(UIKit)
import GhosttyKit

/// Carries a libghostty surface pointer across `GhosttySurfaceView.outputQueue`.
///
/// The pointer is only dereferenced on the serial output queue, and
/// `GhosttySurfaceView.disposeSurface()` orders the eventual free after all
/// already-enqueued queue work.
struct GhosttySurfaceHandle: @unchecked Sendable {
    let pointer: ghostty_surface_t

    init(_ pointer: ghostty_surface_t) {
        self.pointer = pointer
    }
}
#endif
