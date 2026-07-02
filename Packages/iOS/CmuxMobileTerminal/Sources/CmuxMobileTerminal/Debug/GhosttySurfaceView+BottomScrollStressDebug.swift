#if DEBUG
#if canImport(UIKit)
import Foundation
import GhosttyKit

extension GhosttySurfaceView {
    public func debugSetBottomScrollStressPhase(_ phase: String) {
        debugBottomScrollStressPhase = phase
    }

    public var debugIsBottomScrollStressAtBottom: Bool {
        bottomScrollDebugScrollbarAtBottom
    }

    public func debugScrollToBottomForTesting() {
        guard let surface else { return }
        let action = "scroll_to_bottom"
        outputQueue.async {
            action.withCString { pointer in
                _ = ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
            }
        }
    }

    @MainActor
    static func recordBottomScrollDebugScrollbar(total: Int, offset: Int, len: Int, for surface: ghostty_surface_t) {
        view(for: surface)?.debugLastScrollbar = DebugScrollbarSnapshot(total: total, offset: offset, len: len)
    }

    var bottomScrollDebugScrollbarAtBottom: Bool {
        guard let snapshot = debugLastScrollbar else { return false }
        return snapshot.total > snapshot.len && snapshot.offset >= max(0, snapshot.total - snapshot.len - 1)
    }
}
#endif
#endif
