#if DEBUG
public import Combine
public import Foundation

/// A first-settled-wins race owner used by the DEBUG goto-split UI-test recorder
/// to converge on a single capture write once live app state has settled.
///
/// This is the lifted scaffold that the goto-split recorder hand-rolled
/// identically three times (the browser-split focus wait, the address-bar-exit
/// web-view focus wait, and the split-zoom settle wait). Each site declared a
/// local `var resolved = false`, a `var observers: [NSObjectProtocol] = []`, a
/// `var panelsCancellable: AnyCancellable?`, and a `cleanup()` that removed the
/// observers and cancelled the subscription; registered several
/// `NotificationCenter` observers plus a panels-publisher subscription that each
/// re-ran an `evaluate` closure; armed a `DispatchQueue.main.asyncAfter` timeout
/// fallback; and finished exactly once (`guard !resolved; resolved = true;
/// cleanup(); <write>`). Only that scaffold moves here.
///
/// The per-site logic stays app-side: the trigger registrations (which
/// `Notification.Name`s, which surface-id / `WKWebView`-identity filters), the
/// panels publisher, the `evaluate` predicate (`AppDelegate.isWebViewFocused`,
/// `Workspace` / `BrowserPanel` reads), the timeout cadence, and the capture
/// payloads are all supplied by the app-target recorder, which holds the live
/// `AppDelegate` a lower package cannot reference. The recorder hands this owner
/// its observer tokens and subscription via ``track(_:)-(any_NSObjectProtocol)``
/// / ``track(_:)-(AnyCancellable)``, reads ``isResolved`` in its `evaluate`
/// guards, and routes its one-shot finish through ``resolveOnce(_:)``.
///
/// Faithfulness: ``resolveOnce(_:)`` reproduces the legacy finish exactly
/// (`guard !resolved` → `resolved = true` → `cleanup()` → the supplied write),
/// and ``cleanup()`` reproduces the legacy teardown (remove every tracked
/// observer, then cancel the subscription). The legacy timeout in the
/// browser-split site called `cleanup()` *without* setting `resolved`, which
/// ``cleanup()`` preserves (it does not flip the flag); the only adopted unifying
/// delta is that ``cleanup()`` always nils the tracked subscription after
/// cancelling it, which that one site previously skipped. Cancelling is
/// idempotent and the reference was function-local, so the nil is unobservable.
///
/// Isolation: `@MainActor`. The state machine lives where its callers live: the
/// recorder registers triggers, evaluates, and finishes entirely on the main
/// actor, and every `NotificationCenter` observer and the timeout fall back to
/// `DispatchQueue.main`. Co-locating the flag with those callers keeps the finish
/// a plain synchronous call (no actor hop could be introduced without opening a
/// suspension window the out-of-process XCUITest snapshots would observe). This
/// is the established `#if DEBUG` UI-test-scaffold shape in this package, the same
/// `@MainActor` resource-owner co-located with its main-thread callers as
/// ``UITestPollTimer``.
@MainActor
public final class UITestSettleWaiter {
    private var resolved = false
    private var observers: [any NSObjectProtocol] = []
    private var cancellable: AnyCancellable?

    /// Creates an unresolved waiter with no tracked triggers.
    public init() {}

    /// Whether the race has already been resolved. The recorder reads this at the
    /// top of its `evaluate` predicate and inside the timeout fallback to skip
    /// stale work, exactly as the legacy `guard !resolved` did.
    public var isResolved: Bool { resolved }

    /// Tracks a `NotificationCenter` observer token so ``cleanup()`` can remove it.
    ///
    /// - Parameter token: The opaque observer returned by
    ///   `NotificationCenter.default.addObserver(forName:object:queue:using:)`.
    public func track(_ token: any NSObjectProtocol) {
        observers.append(token)
    }

    /// Tracks the panels-publisher subscription so ``cleanup()`` can cancel it.
    ///
    /// Replaces the prior subscription if called more than once, matching the
    /// legacy single `panelsCancellable` slot.
    ///
    /// - Parameter cancellable: The `sink` subscription to retain until teardown.
    public func track(_ cancellable: AnyCancellable) {
        self.cancellable = cancellable
    }

    /// Removes every tracked observer and cancels the tracked subscription.
    ///
    /// Does not flip ``isResolved``: the browser-split timeout fallback relied on
    /// tearing down its triggers without marking the race resolved.
    public func cleanup() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        cancellable?.cancel()
        cancellable = nil
    }

    /// Resolves the race exactly once, tearing down the triggers and then running
    /// the supplied completion.
    ///
    /// Reproduces the legacy one-shot finish: a no-op if already resolved,
    /// otherwise it flips ``isResolved``, runs ``cleanup()``, and then runs
    /// `work` (the capture write). `work` runs synchronously after teardown, so
    /// the completion observes the torn-down state, matching the legacy
    /// `resolved = true; cleanup(); writeData(...)` order.
    ///
    /// - Parameter work: The completion to run once, after teardown.
    public func resolveOnce(_ work: () -> Void) {
        guard !resolved else { return }
        resolved = true
        cleanup()
        work()
    }
}
#endif
