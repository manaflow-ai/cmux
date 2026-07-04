import AppKit

@MainActor
final class WindowKeyNotificationObservers {
    private let notificationCenter: NotificationCenter
    private var didBecomeKeyObserver: NSObjectProtocol?
    private var didResignKeyObserver: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    isolated deinit {
        removeAll()
    }

    func install(for window: NSWindow, onKeyStateChange: @MainActor @escaping () -> Void) {
        removeAll()
        didBecomeKeyObserver = notificationCenter.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in onKeyStateChange() }
        }
        didResignKeyObserver = notificationCenter.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in onKeyStateChange() }
        }
    }

    func removeAll() {
        if let didBecomeKeyObserver {
            notificationCenter.removeObserver(didBecomeKeyObserver)
            self.didBecomeKeyObserver = nil
        }
        if let didResignKeyObserver {
            notificationCenter.removeObserver(didResignKeyObserver)
            self.didResignKeyObserver = nil
        }
    }
}
