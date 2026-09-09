import AppKit
import CmuxWindowing

@MainActor
final class MainWindowController: ReleasingWindowController {
    var onClose: ((NSWindow) -> Void)?
    var shouldClose: ((NSWindow) -> Bool)?
    var onFrameRestorationCheckpoint: ((NSWindow) -> Void)?
    /// Reports AppKit geometry callbacks for this window to its lifecycle owner.
    var onGeometryChanged: ((NSWindow) -> Void)?

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

    func windowDidExitFullScreen(_ notification: Notification) {
        handleFrameRestorationCheckpoint("didExitFullScreen", notification: notification)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        handleFrameRestorationCheckpoint("didDeminiaturize", notification: notification)
    }

    /// Forwards a completed AppKit move callback for the managed window.
    func windowDidMove(_ notification: Notification) {
        handleGeometryChange(notification)
    }

    /// Forwards a completed AppKit resize callback for the managed window.
    func windowDidResize(_ notification: Notification) {
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

    /// Delivers a geometry callback only when it belongs to the managed window.
    private func handleGeometryChange(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === window else {
            return
        }
        onGeometryChanged?(changedWindow)
    }
}
