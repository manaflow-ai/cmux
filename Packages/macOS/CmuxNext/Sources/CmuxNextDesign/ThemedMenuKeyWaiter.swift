import AppKit
import CmuxNextCompat

/// Waits, once, for a closing menu's window to give up the keys: its `didResignKey` or `willClose`
/// notification, whichever AppKit posts first, then runs the chosen row (``ThemedMenuRowView``).
@MainActor
final class ThemedMenuKeyWaiter {
    private let window: NSWindow
    private var then: (@MainActor () -> Void)?
    private var observers: [MainActorObservation] = []

    init(window: NSWindow, then: @escaping @MainActor () -> Void) {
        self.window = window
        self.then = then
    }

    /// Starts waiting; `finished` runs after the row's run.
    func start(finished: @escaping @MainActor () -> Void) {
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(MainActorObservation(name, object: window) { [weak self] in
                self?.fire()
                finished()
            })
        }
    }

    private func fire() {
        observers.removeAll()
        observers = []
        let body = then
        then = nil
        body?()
    }
}
