import AppKit
import CmuxNextDesign

// fullscreen-lag (user, 2026-10-19). A full screen enter or exit is one
// AppKit animation from the old size to the new one; the window takes the new
// size at its start. Nothing springs toward it (`Motion.isLiveResizing` holds
// for the transition), terminals send the daemon one grid at its end
// (`ResizeCoordinator`), hover cards close (their anchors move), and the top
// row lays out for where it rests: the traffic lights are away while the
// window leaves full screen (`ShellWindow.restingTrafficLights`), and once
// they are back every strip under them measures again.
extension WindowController {
    func windowWillEnterFullScreen(_ notification: Notification) {
        services.hoverCards.dismiss(.action)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenTransitionDidEnd()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        Motion.fullScreenTransitionFailed(window)
        fullScreenTransitionDidEnd()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        services.hoverCards.dismiss(.action)
        (window as? ShellWindow)?.isLeavingFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransitionDidEnd()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        Motion.fullScreenTransitionFailed(window)
        fullScreenTransitionDidEnd()
    }

    /// The lights are where they rest again (or gone, in full screen): the
    /// top row and every strip under it measure once more, in this turn.
    private func fullScreenTransitionDidEnd() {
        (window as? ShellWindow)?.isLeavingFullScreen = false
        root.needsLayout = true // invalidate: the full-screen transition ended; the traffic lights moved.
        // sync-layout: relayoutTopRowStrips reads the strips' window frames and the top row the root places.
        root.layoutSubtreeIfNeeded()
        relayoutTopRowStrips()
    }
}
