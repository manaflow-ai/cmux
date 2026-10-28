import AppKit
import CmuxNextDesign
import CmuxNextInput
import CmuxNextSignposts

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

    /// A live-resize tick is one `resize.frame`, from the drag that moved the edge to the
    /// commit that shows it: the delegate hears each frame change, as Chromium's NSWindow delegate does
    /// (components/remote_cocoa/app_shim/views_nswindow_delegate.mm `windowDidResize:`).
    /// A full-screen transition's frames come from no drag, so they are none.
    func windowDidResize(_ notification: Notification) {
        guard window?.inLiveResize == true, let drag = services.inputTap.actionEvent, drag.type == .leftMouseDragged else { return }
        (NSApp as? CmuxApplication)?.inputFrames.resizeTick(eventTimestamp: drag.timestamp)
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
