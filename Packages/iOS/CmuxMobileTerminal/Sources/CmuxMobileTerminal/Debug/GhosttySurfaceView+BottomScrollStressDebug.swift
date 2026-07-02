#if DEBUG
#if canImport(UIKit)
import Foundation
import GhosttyKit

extension GhosttySurfaceView {
    /// Sets the accessibility-visible bottom-scroll stress phase.
    public func setBottomScrollStressPhase(_ phase: String) {
        debugBottomScrollStressPhase = phase
    }

    /// Whether the last debug scrollbar callback reports the surface at bottom.
    public var isBottomScrollStressAtBottom: Bool {
        bottomScrollDebugScrollbarAtBottom
    }

    /// Sends Ghostty's scroll-to-bottom action for the bottom-scroll stress harness.
    public func scrollToBottomForBottomScrollStress() {
        guard let surface else { return }
        let action = "scroll_to_bottom"
        outputQueue.async {
            action.withCString { pointer in
                _ = ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
            }
        }
    }

    var bottomScrollDebugScrollbarAtBottom: Bool {
        guard let snapshot = lastScrollbarSnapshot else { return false }
        return snapshot.total > snapshot.len && snapshot.offset >= max(0, snapshot.total - snapshot.len - 1)
    }
}
#endif
#endif
