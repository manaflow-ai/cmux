public import AppKit
import Observation

/// Owns window identity and lifecycle for the app's main windows, and nothing
/// else.
///
/// This is the de-aggregation keystone. The legacy `AppDelegate.MainWindowContext`
/// fused tabs, sidebar, focus, file-explorer, config, the close observer, and
/// the `NSWindow` handle into one per-window object keyed by `ObjectIdentifier`.
/// The owner ruling (2026-06-18) rejects that aggregate: per-window state is
/// domain-owned and `WindowID`-keyed, looked up by each domain in its own
/// `[WindowID: Model]`. `WindowCoordinator` keeps only the irreducible window
/// layer: the live ``WindowID`` set, the `NSWindow` handle for each, and one
/// single-consumer window-closed stream whose sole consumer (the app's
/// teardown loop) runs teardown and drops every domain's per-window slice.
///
/// ## Isolation
///
/// `@MainActor` because every mutator originates on the main thread from AppKit
/// (`register` is called while building a window; the close observation fires on
/// `NSWindow.willCloseNotification`, a main-thread notification). Co-locating the
/// state with its callers turns what would have been cross-actor bridges into
/// plain calls. The window-closed stream is the only cross-context surface and
/// it carries `Sendable` ``WindowID`` values.
///
/// ## Lifecycle
///
/// Registering a window installs a `willClose` observation owned by this
/// coordinator (the responsibility drained from `MainWindowContext.closeObserver`).
/// When a window closes, the coordinator drops it from the live ``WindowID`` set
/// and yields its ``WindowID`` on ``windowClosed`` exactly once. The app target's
/// `unregisterMainWindow` AppKit path subscribes and drives the rest of teardown
/// one main-actor turn later. Because that consumer is deferred and a
/// `CmuxMainWindow` is released the instant its controller drops (stock
/// `isReleasedWhenClosed = true`), the coordinator pins the closing `NSWindow`
/// strongly from `willClose` until the consumer calls ``unregister(_:)``, so the
/// deferred teardown can always resolve the window and is never silently dropped
/// by autorelease timing.
@MainActor
@Observable
public final class WindowCoordinator: WindowManaging {
    /// Live window identifiers. `@Observable` so window-count-dependent UI can
    /// track it without a manual notification.
    public private(set) var windowIds: Set<WindowID> = []

    /// Handle and close-observation owned per window. Not observed because the
    /// `NSWindow` reference is plumbing, not view state.
    @ObservationIgnored
    private var entries: [WindowID: Entry] = [:]

    @ObservationIgnored
    private let closedContinuation: AsyncStream<WindowID>.Continuation

    public nonisolated let windowClosed: AsyncStream<WindowID>

    /// Creates an empty coordinator. The app target constructs exactly one at
    /// the composition root and injects it as `any WindowManaging`.
    public init() {
        let (stream, continuation) = AsyncStream<WindowID>.makeStream(bufferingPolicy: .unbounded)
        self.windowClosed = stream
        self.closedContinuation = continuation
    }

    public func register(_ window: NSWindow, id: WindowID) {
        // Replace any prior observation for this id (window recreated during
        // restore reuses the WindowID).
        entries[id]?.invalidate()
        let entry = Entry(window: window) { [weak self] in
            self?.handleClose(of: id)
        }
        entries[id] = entry
        windowIds.insert(id)
    }

    @discardableResult
    public func unregister(_ id: WindowID) -> NSWindow? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        windowIds.remove(id)
        let window = entry.resolvedWindow
        entry.invalidate()
        return window
    }

    public func window(for id: WindowID) -> NSWindow? {
        entries[id]?.resolvedWindow
    }

    public func id(for window: NSWindow) -> WindowID? {
        entries.first(where: { $0.value.resolvedWindow === window })?.key
    }

    /// AppKit told us a registered window is closing: drop it from the live set,
    /// yield its id exactly once on the single-consumer ``windowClosed`` stream,
    /// and keep the ``Entry`` (now pinning the closing `NSWindow` strongly) in
    /// `entries` until the consumer calls ``unregister(_:)`` on the deferred
    /// turn.
    ///
    /// The entry is intentionally NOT removed here. The close broadcast is
    /// consumed one main-actor turn later (the app's `unregisterMainWindow` runs
    /// off the `windowClosed` `AsyncStream`), and the closing `CmuxMainWindow` is
    /// created with the stock `isReleasedWhenClosed = true` default, so its only
    /// strong owner (`AppDelegate.mainWindowControllers`) is gone by the time
    /// `willClose` dispatch unwinds. If the entry held the window weakly, the
    /// autorelease pool could drain the window before the deferred consumer
    /// resolves it, silently dropping the entire teardown (geometry persist,
    /// closed-window history, active-window repoint, session-snapshot save,
    /// command-palette removal, notification clearing). The entry pins the
    /// closing window strongly across this one-turn gap so resolution cannot
    /// fail; `unregister(_:)` releases the pin and the window deallocates then.
    private func handleClose(of id: WindowID) {
        guard let entry = entries[id] else { return }
        entry.pinClosingWindow()
        windowIds.remove(id)
        closedContinuation.yield(id)
    }

    /// One window's handle plus its `willClose` observation. A `@MainActor`
    /// `NSObject` using the selector-based `NotificationCenter` API, mirroring
    /// the app target's proven `WindowCloseObserver` so the close callback is
    /// statically main-actor-isolated (no `assumeIsolated`, which the refactor
    /// owner has ruled an anti-pattern).
    @MainActor
    private final class Entry: NSObject {
        /// Weak while the window is open: the coordinator must not keep a live
        /// window alive past its owner's intent.
        private weak var window: NSWindow?

        /// Strong only once the window is closing. Pinned synchronously inside
        /// `willClose` (where the window is provably still alive) and held until
        /// ``WindowCoordinator/unregister(_:)`` releases the entry, so the
        /// deferred close consumer can resolve the closing window even after the
        /// autorelease pool would otherwise have drained it (see
        /// ``WindowCoordinator/handleClose(of:)``).
        private var closingWindow: NSWindow?

        private let onClose: @MainActor () -> Void

        /// The closing window if pinned, otherwise the still-open weak window.
        var resolvedWindow: NSWindow? { closingWindow ?? window }

        init(window: NSWindow, onClose: @escaping @MainActor () -> Void) {
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

        /// Promotes the weak window reference to a strong one for the duration of
        /// the close cycle. Called from ``WindowCoordinator/handleClose(of:)``
        /// during the `willClose` turn, where `window` is still non-nil.
        func pinClosingWindow() {
            closingWindow = window
        }

        func invalidate() {
            NotificationCenter.default.removeObserver(self)
            closingWindow = nil
        }

        @objc
        private func windowWillClose(_ notification: Notification) {
            guard let closingWindow = notification.object as? NSWindow,
                  closingWindow === window else { return }
            onClose()
        }
    }
}
