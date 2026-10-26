import AppKit
import CmuxNextWakeups

/// Key-window changes refresh that window's hover (`PointerHover`), through one ``AppEvents``
/// subscription per notice for the process. A notice reaches it in the change's own turn, so key
/// changes and closes keep their synchronous order. AppKit has one key window: the window that
/// resigns is the one that last became key, so it is remembered here, not read from the notice.
@MainActor
final class KeyWindowObserver {
    private let events: AppEvents
    private var subscriptions: [EventSubscription] = []
    /// The key window as of the last become-key notice (or the install).
    private weak var key: NSWindow?

    /// - Parameters:
    ///   - events: Where the key notices arrive (the app's center; tests pass their own).
    ///   - keyWindow: The key window now (`NSApp.keyWindow`).
    ///   - changed: Refreshes the hover of the window a notice moved the keyboard to or from.
    init(events: AppEvents, keyWindow: @escaping @MainActor () -> NSWindow?, changed: @escaping @MainActor (NSWindow?) -> Void) {
        self.events = events
        key = keyWindow()
        subscriptions = [
            events.subscribe(NSWindow.didBecomeKeyNotification, owner: "PointerHover.key") { [weak self] in
                let window = keyWindow()
                self?.key = window
                changed(window)
            },
            events.subscribe(NSWindow.didResignKeyNotification, owner: "PointerHover.key") { [weak self] in
                let window = self?.key
                self?.key = nil
                changed(window)
            },
        ]
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// A closed window's synthesized pointer must not pass to a new window that reuses its address:
    /// each window with one drops it when it closes.
    private var closes: [ObjectIdentifier: EventSubscription] = [:]

    func forgetPointer(whenClosing window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard closes[id] == nil else { return }
        closes[id] = WindowEvents.of(window).subscribe(NSWindow.willCloseNotification, owner: "PointerHover.debugPointer") { [weak self] in
            PointerHover.debugPointers[id] = nil
            self?.closes[id] = nil
        }
    }
    #endif
}
