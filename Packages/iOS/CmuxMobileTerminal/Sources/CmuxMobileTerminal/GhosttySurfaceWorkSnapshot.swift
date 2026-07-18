#if canImport(UIKit)
import GhosttyKit

/// A surface pointer paired with the serial queue that owns its lifetime.
/// Disposal is enqueued on this same queue, so earlier work may safely retain
/// the pointer without allowing concurrent libghostty access.
struct GhosttySurfaceWorkSnapshot: @unchecked Sendable {
    let surface: ghostty_surface_t
    let generation: UInt64
    let scale: Double
    let queue: GhosttySurfaceWorkQueue
}
#endif
