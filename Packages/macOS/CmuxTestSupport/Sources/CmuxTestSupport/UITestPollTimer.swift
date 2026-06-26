#if DEBUG
internal import Dispatch

/// A main-queue repeating poll timer used by the DEBUG UI-test recorders to
/// sample live app state on a fixed cadence.
///
/// This is the lifted timer-source scaffold shared by the goto-split recorder's
/// two pollers (the browser-panel recorder and the record-only find-state
/// recorder). Both built a `DispatchSourceTimer` on `DispatchQueue.main`,
/// scheduled it at `.now()` repeating every 100 ms, attached a per-tick event
/// handler, and resumed it, cancelling any previous timer first. Only that
/// scaffold moves here. The per-tick body stays app-side: it reads live
/// `TabManager` / `Workspace` / `BrowserPanel` state that a lower package cannot
/// reference, so each call site passes its own event-handler closure to
/// ``start(intervalMilliseconds:tick:)``.
///
/// Faithfulness: ``start(intervalMilliseconds:tick:)`` reproduces the legacy
/// `cancel old → makeTimerSource(queue: .main) → schedule(deadline: .now(),
/// repeating:) → setEventHandler → resume` sequence exactly, and the default
/// 100 ms interval matches both recorders. The `tick` closure is the same
/// closure the recorders previously handed straight to `setEventHandler`, so its
/// synchronous-vs-`Task` semantics are unchanged per call site. ``deinit``
/// cancels the live timer, matching the recorder's former
/// `deinit { recorderTimer?.cancel() }`.
///
/// Isolation: `@MainActor`. The timer genuinely lives on the main queue: it is
/// created, scheduled, and torn down from the main actor, and its event handler
/// fires on `DispatchQueue.main` (the main thread). The owned
/// `DispatchSourceTimer` is never exposed; it is a private resource handle whose
/// single closer is ``deinit`` (or the next ``start(intervalMilliseconds:tick:)``).
/// This is the established `#if DEBUG` UI-test-scaffold shape in this package (a
/// `@MainActor` resource owner co-located with its main-thread callers, like
/// `CmuxMainRunLoopStallMonitor`) rather than an actor + `AsyncStream`: the
/// recorders need the timer's exact synchronous main-queue tick cadence that the
/// out-of-process XCUITest snapshots depend on, and an async hop would change it.
@MainActor
public final class UITestPollTimer {
    private var timer: DispatchSourceTimer?

    /// Creates an idle poll timer. Call ``start(intervalMilliseconds:tick:)`` to
    /// arm it.
    public init() {}

    deinit {
        timer?.cancel()
    }

    /// Arms a repeating main-queue timer, cancelling any timer already running.
    ///
    /// - Parameters:
    ///   - intervalMilliseconds: The repeat interval in milliseconds; defaults to
    ///     the recorders' 100 ms cadence.
    ///   - tick: The event handler fired on `DispatchQueue.main` every interval.
    ///     Supplied by the app-target recorder because it reads live app state;
    ///     its isolation and synchronous-vs-`Task` shape are preserved as written
    ///     at the call site.
    public func start(intervalMilliseconds: Int = 100, tick: @escaping () -> Void) {
        timer?.cancel()
        timer = nil

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(intervalMilliseconds))
        source.setEventHandler(handler: tick)
        timer = source
        source.resume()
    }
}
#endif
