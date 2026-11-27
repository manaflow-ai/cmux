import AppKit

@MainActor
final class WindowCloseObserver: NSObject {
    private weak var window: NSWindow?
    private let onClose: @MainActor (NSWindow) -> Void

    init(window: NSWindow, onClose: @escaping @MainActor (NSWindow) -> Void) {
        self.window = window
        self.onClose = onClose
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        onClose(closingWindow)
    }
}
