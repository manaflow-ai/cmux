import AppKit

/// Waits, once, for a closing menu's window to give up the keys: its `didResignKey` or `willClose`
/// notification, whichever AppKit posts first, then runs the chosen row (``ThemedMenuRowView``).
@MainActor
final class ThemedMenuKeyWaiter {
    private let window: NSWindow
    private var then: (@MainActor () -> Void)?
    private var observers: [any NSObjectProtocol] = []

    init(window: NSWindow, then: @escaping @MainActor () -> Void) {
        self.window = window
        self.then = then
    }

    /// Starts waiting; `finished` runs after the row's run.
    func start(finished: @escaping @MainActor () -> Void) {
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { // main-proof: observer on queue: .main
                    self?.fire()
                    finished()
                }
            })
        }
    }

    private func fire() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let body = then
        then = nil
        body?()
    }
}
