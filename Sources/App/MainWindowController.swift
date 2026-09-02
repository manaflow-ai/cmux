import AppKit
import CmuxWindowing

@MainActor
final class MainWindowController: ReleasingWindowController {
    var onClose: (() -> Void)?
    var shouldClose: ((NSWindow) -> Bool)?
    var onFrameRestorationCheckpoint: ((NSWindow) -> Void)?

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
        onClose?()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        handleFrameRestorationCheckpoint("didExitFullScreen", notification: notification)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        handleFrameRestorationCheckpoint("didDeminiaturize", notification: notification)
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
}
