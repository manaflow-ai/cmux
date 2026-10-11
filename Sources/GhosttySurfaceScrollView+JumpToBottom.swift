import AppKit
import CmuxTerminal
import CmuxTerminalCore

@MainActor
extension GhosttySurfaceScrollView {
    /// Refreshes the "Jump to Bottom" pill from the surface's newest
    /// scrollbar packet.
    func synchronizeJumpToBottomIndicator() {
        let cellWidth = surfaceView.cellSize.width
        let columns = cellWidth > 0 ? Int(surfaceView.bounds.width / cellWidth) : 0
        jumpToBottomIndicatorView.update(
            scrollbar: surfaceView.scrollbar,
            columns: columns
        ) { [weak self] in
            self?.surfaceView.terminalSurface?.isAlternateScreenActive() ?? false
        }
    }

    /// Scrolls the terminal viewport to the live bottom and resumes following
    /// output. The shared path behind the pill and the "Scroll to Bottom"
    /// command palette entry.
    ///
    /// - Parameter focusTerminal: Makes this terminal the focused pane, as a
    ///   click inside it would.
    /// - Returns: `false` when the pane has no live terminal surface.
    @discardableResult
    func scrollTerminalToBottom(focusTerminal: Bool) -> Bool {
        clearPendingNotificationScrollRestore()
        // Resolve follow intent before the packet arrives, so the passive
        // bottom packet moves the scroller with the terminal.
        let previousIntent = prepareExplicitViewportRestore(isAtBottom: true)
        guard surfaceView.performBindingAction("scroll_to_bottom") else {
            rollbackExplicitViewportRestore(to: previousIntent)
            return false
        }
        if focusTerminal {
            surfaceView.focusFromPointerDown()
        }
        return true
    }

    func installJumpToBottomIndicator() {
        jumpToBottomIndicatorView.onJump = { [weak self] in
            _ = self?.scrollTerminalToBottom(focusTerminal: true)
        }
        addSubview(jumpToBottomIndicatorView)
    }
}
