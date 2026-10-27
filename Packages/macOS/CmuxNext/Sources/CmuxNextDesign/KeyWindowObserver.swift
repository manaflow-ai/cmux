import AppKit
import CmuxNextWakeups

/// Key-window and app-activity changes refresh hover (`PointerHover`), through one ``AppEvents``
/// subscription per notice for the process. A notice reaches it in the change's own turn, so key
/// changes and closes keep their synchronous order. AppKit has one key window: the window that
/// resigns is the one that last became key, so it is remembered here, not read from the notice.
/// An `.activeForHover` tracking area hears no exit while another app is active, so cmux resigning
/// active ends the hovers that exit would have ended: the targets' (`activityChanged`) and those of
/// the owners that track their own enter and exit, which it calls directly (`watchDeactivation`).
@MainActor
final class KeyWindowObserver {
    private let events: AppEvents
    private var subscriptions: [EventSubscription] = []
    /// The hover owners to clear at the next deactivation, in watch order (a handful: the hovers that
    /// show). Held weakly: a released watch drops out by itself.
    private var watches: [WeakWatch] = []

    private struct WeakWatch {
        weak var watch: HoverDeactivationWatch?
    }
    /// The key window as of the last become-key notice (or the install).
    private weak var key: NSWindow?
    /// Whether cmux is the active app as of the last activity notice: active until a resign notice
    /// says otherwise (an app activates as it launches).
    private(set) var isAppActive = true

    /// - Parameters:
    ///   - events: Where the key and activity notices arrive (the app's center; tests pass their own).
    ///   - keyWindow: The key window now (`NSApp.keyWindow`).
    ///   - changed: Refreshes the hover of the window a notice moved the keyboard to or from.
    ///   - activityChanged: Refreshes the hovers an activation or a deactivation changes; gets the key window now.
    init(events: AppEvents, keyWindow: @escaping @MainActor () -> NSWindow?, changed: @escaping @MainActor (NSWindow?) -> Void,
         activityChanged: @escaping @MainActor (NSWindow?) -> Void = { _ in }) {
        self.events = events
        key = keyWindow()
        subscriptions = [
            events.subscribe(NSApplication.didResignActiveNotification, owner: "PointerHover.activity") { [weak self] in
                self?.isAppActive = false
                activityChanged(keyWindow())
                self?.clearWatchedHovers()
            },
            events.subscribe(NSApplication.didBecomeActiveNotification, owner: "PointerHover.activity") { [weak self] in
                self?.isAppActive = true
                activityChanged(keyWindow())
            },
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

    /// Calls `clear` at the next deactivation while the returned watch lives.
    func watchDeactivation(_ clear: @escaping @MainActor () -> Void) -> HoverDeactivationWatch {
        let watch = HoverDeactivationWatch(clear)
        watches.removeAll { $0.watch == nil }
        watches.append(WeakWatch(watch: watch))
        return watch
    }

    /// Each live watch clears once, in watch order; a clear that releases a later watch skips it.
    private func clearWatchedHovers() {
        let now = watches
        watches.removeAll { $0.watch == nil }
        for entry in now { entry.watch?.fire() }
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

/// A hover owner's watch for cmux resigning active (`PointerHover.clearOnDeactivation`): its clear
/// runs at the next deactivation while the owner holds the watch. Releasing it (or `cancel()`) ends it.
@MainActor
public final class HoverDeactivationWatch {
    private var clear: (@MainActor () -> Void)?

    fileprivate init(_ clear: @escaping @MainActor () -> Void) {
        self.clear = clear
    }

    /// Ends the watch now. Idempotent.
    public func cancel() {
        clear = nil
    }

    fileprivate func fire() {
        clear?()
    }
}
