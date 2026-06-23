#if canImport(UIKit)
import GhosttyKit
import Foundation

/// Serial owner for one Ghostty surface generation.
///
/// A synchronous `ghostty_surface_render_now` can block inside libghostty or the
/// platform renderer. The important safety property is that every C call for a
/// given `ghostty_surface_t` is ordered on that generation's executor, including
/// eventual free. If a generation stalls, the view can abandon this executor and
/// create a new surface generation without freeing under the blocked call.
final class GhosttySurfaceWorkExecutor {
    let generation: UInt64
    private let queue: DispatchQueue

    init(generation: UInt64) {
        self.generation = generation
        self.queue = DispatchQueue(
            label: "dev.cmux.GhosttySurfaceView.surface.\(generation)",
            qos: .userInitiated
        )
    }

    func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    func async(execute workItem: DispatchWorkItem) {
        queue.async(execute: workItem)
    }

    func async(
        surface: ghostty_surface_t,
        _ work: @escaping @Sendable (GhosttySurfaceWorkHandle) -> Void
    ) {
        let handle = GhosttySurfaceWorkHandle(surface: surface)
        queue.async {
            work(handle)
        }
    }

    func retire(surface: ghostty_surface_t, bridge: GhosttySurfaceBridge) {
        let surfaceHandle = GhosttySurfaceWorkHandle(surface: surface)
        let bridgeRetain = GhosttySurfaceBridgeRetain(bridge)
        queue.async {
            ghostty_surface_free(surfaceHandle.surface)
            bridgeRetain.release()
        }
    }
}
#endif
