import AppKit

@MainActor
final class WindowCloseObserver {
    private var token: NSObjectProtocol?

    init(window: NSWindow, onClose: @escaping @MainActor (NSWindow) -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                onClose(window)
            }
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
