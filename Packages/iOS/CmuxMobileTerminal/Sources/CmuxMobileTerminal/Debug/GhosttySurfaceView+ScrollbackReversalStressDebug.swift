#if DEBUG
#if canImport(UIKit)
import Foundation
import GhosttyKit

extension GhosttySurfaceView {
    var debugScrollbarAtBottomForTesting: Bool {
        guard let snapshot = debugLastScrollbar else { return false }
        return snapshot.total > snapshot.len && snapshot.offset >= max(0, snapshot.total - snapshot.len - 1)
    }

    /// Sets the accessibility-visible scrollback reversal stress phase.
    func setScrollbackReversalStressPhase(_ phase: String) {
        debugScrollbackReversalStressPhase = phase
    }

    /// Records a scrollback reversal stress failure code for the UI test probe.
    func setScrollbackReversalStressFailure(_ failure: String) {
        debugScrollbackReversalStressFailure = failure.replacingOccurrences(of: ";", with: ",")
    }

    /// Sends Ghostty's scroll-to-bottom action for the scrollback reversal stress harness.
    func scrollToBottomForScrollbackReversalStress() {
        discardPendingLocalScrollbackScroll()
        enqueueScrollToBottom()
    }

    /// Last debug scrollbar offset reported by libghostty.
    var scrollbackReversalStressOffset: Int? {
        debugLastScrollbar?.offset
    }

    /// Reads the current viewport text on the serial Ghostty output queue.
    func scrollbackReversalViewportText() async -> String? {
        guard let state = localScrollbackScrollState() else { return nil }
        return await withCheckedContinuation { continuation in
            state.queue.async {
                let text = Self.surfaceText(state.surface, pointTag: GHOSTTY_POINT_VIEWPORT)
                continuation.resume(returning: text)
            }
        }
    }

    /// Whether the last debug scrollbar callback reports the surface at bottom.
    var isScrollbackReversalStressAtBottom: Bool {
        guard let snapshot = debugLastScrollbar else { return false }
        return snapshot.total > snapshot.len && snapshot.offset >= max(0, snapshot.total - snapshot.len - 1)
    }
}
#endif
#endif
