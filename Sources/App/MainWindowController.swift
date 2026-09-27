import AppKit
import CmuxWindowing

@MainActor
final class MainWindowController: ReleasingWindowController {
    var onClose: ((NSWindow) -> Void)?
    var shouldClose: ((NSWindow) -> Bool)?
    var onFrameRestorationCheckpoint: ((NSWindow) -> Void)?
    /// Reports AppKit geometry callbacks for this window to its lifecycle owner.
    var onGeometryChanged: ((NSWindow) -> Void)?
    /// Lifecycle policy for treating a non-live-resize callback as deliberate placement.
    var shouldRetireZoomIntentForProgrammaticResize: ((CmuxMainWindow) -> Bool) = { _ in true }

    private var isFullScreenTransitionInProgress = false

#if DEBUG
    private func logWindowEvent(_ event: String, notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let id = window.identifier?.rawValue ?? "<nil>"
        cmuxDebugLog(
            "mainWindow.delegate.\(event) window=\(id) visible=\(window.isVisible ? 1 : 0) mini=\(window.isMiniaturized ? 1 : 0) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
        )
    }
#endif

    override func managedWindowWillClose(_ window: NSWindow) {
        onClose?(window)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        setFullScreenTransitionInProgress(true, notification: notification)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        setFullScreenTransitionInProgress(false, notification: notification)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        guard window === self.window else { return }
        isFullScreenTransitionInProgress = false
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        setFullScreenTransitionInProgress(true, notification: notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        setFullScreenTransitionInProgress(false, notification: notification)
        handleFrameRestorationCheckpoint("didExitFullScreen", notification: notification)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard window === self.window else { return }
        isFullScreenTransitionInProgress = false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        handleFrameRestorationCheckpoint("didDeminiaturize", notification: notification)
    }

    /// Clears zoom intent when AppKit starts moving the window. A click passed
    /// to performDrag(with:) can finish without ever producing this callback.
    func windowWillMove(_ notification: Notification) {
        handleUserPlacement(notification)
    }

    /// Includes native Window-menu and green-button tiling, whose animations
    /// emit live-resize callbacks without passing through setFrame(_:display:).
    func windowWillStartLiveResize(_ notification: Notification) {
        handleUserPlacement(notification)
    }

    /// Forwards a completed AppKit move callback for the managed window.
    func windowDidMove(_ notification: Notification) {
        handleGeometryChange(notification)
    }

    /// Treats an unowned resize callback as deliberate placement, then forwards it.
    func windowDidResize(_ notification: Notification) {
        handleProgrammaticResizePlacement(notification)
        handleGeometryChange(notification)
    }

    /// Forwards a completed AppKit screen-change callback for the managed window.
    func windowDidChangeScreen(_ notification: Notification) {
        handleGeometryChange(notification)
    }

#if DEBUG
    func windowDidMiniaturize(_ notification: Notification) {
        logWindowEvent("didMiniaturize", notification: notification)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        logWindowEvent("didBecomeKey", notification: notification)
    }

    func windowDidResignKey(_ notification: Notification) {
        logWindowEvent("didResignKey", notification: notification)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        logWindowEvent("didBecomeMain", notification: notification)
    }

    func windowDidResignMain(_ notification: Notification) {
        logWindowEvent("didResignMain", notification: notification)
    }
#endif

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let shouldClose = shouldClose?(sender) ?? true
        if shouldClose {
            WebViewInspectorTeardown.closeAllInspectors(in: sender)
        }
        return shouldClose
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard window is CmuxMainWindow else { return newFrame }
        return CmuxMainWindow.standardFrame(forDefaultFrame: newFrame)
    }

    private func handleFrameRestorationCheckpoint(
        _ event: String,
        notification: Notification
    ) {
        guard let restoredWindow = notification.object as? NSWindow,
              restoredWindow === window else {
            return
        }
#if DEBUG
        logWindowEvent(event, notification: notification)
#endif
        onFrameRestorationCheckpoint?(restoredWindow)
    }

    /// Retires stale zoom intent for external/programmatic frame assignment while
    /// preserving cmux-owned repair and native fullscreen transition frames.
    private func handleProgrammaticResizePlacement(_ notification: Notification) {
        guard let placedWindow = notification.object as? CmuxMainWindow,
              placedWindow === window,
              placedWindow.cmuxWantsZoomedFrame else {
            return
        }
        if placedWindow.isApplyingManagedPlacement
            || placedWindow.consumeManagedPlacementResizeCallback() {
            return
        }
        guard !placedWindow.isZoomed,
              !isFullScreenTransitionInProgress,
              !placedWindow.styleMask.contains(.fullScreen),
              shouldRetireZoomIntentForProgrammaticResize(placedWindow) else {
            return
        }
        placedWindow.recordUserPlacement()
    }

    private func setFullScreenTransitionInProgress(
        _ isInProgress: Bool,
        notification: Notification
    ) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === window else {
            return
        }
        isFullScreenTransitionInProgress = isInProgress
    }

    /// Delivers a geometry callback only when it belongs to the managed window.
    private func handleGeometryChange(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === window else {
            return
        }
        onGeometryChanged?(changedWindow)
    }

    /// Applies user placement only to the window owned by this controller.
    private func handleUserPlacement(_ notification: Notification) {
        guard let placedWindow = notification.object as? CmuxMainWindow,
              placedWindow === window else {
            return
        }
        placedWindow.recordUserPlacement()
    }
}
