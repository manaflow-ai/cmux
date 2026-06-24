#if canImport(UIKit)
import Foundation

/// Retained bridge carrier for queued surface teardown.
///
/// Safety: the retained object is released on the same generation executor
/// after `ghostty_surface_free`, preserving the C callback context lifetime
/// without capturing a non-Sendable UIKit object directly in a concurrent
/// closure.
struct GhosttySurfaceBridgeRetain: @unchecked Sendable {
    private let retainedBridge: Unmanaged<GhosttySurfaceBridge>

    init(_ bridge: GhosttySurfaceBridge) {
        self.retainedBridge = Unmanaged.passRetained(bridge)
    }

    func release() {
        retainedBridge.release()
    }
}
#endif
