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
        enqueueScrollToBottom()
    }

    @MainActor
    func recordBottomScrollStressScrollbar(total: Int, offset: Int, len: Int) {
        debugLastScrollbar = (total: total, offset: offset, len: len)
    }

    var bottomScrollDebugScrollbarAtBottom: Bool {
        guard let snapshot = debugLastScrollbar else { return false }
        return snapshot.total > snapshot.len && snapshot.offset >= max(0, snapshot.total - snapshot.len - 1)
    }
}
#endif
#endif
