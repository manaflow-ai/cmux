public import Foundation

/// Drives the repeating session-snapshot autosave cadence and the typing-quiet
/// deferral, calling back into the app to perform each save.
///
/// Faithful lift of the autosave-cadence half of the `AppDelegate` session
/// block: the `DispatchSource` repeating timer (``start()`` /
/// ``stop()``), the in-flight latch (`sessionAutosaveTickInFlight`), the
/// typing-quiet deferral (`remainingSessionAutosaveTypingQuietPeriod` +
/// `scheduleDeferredSessionAutosaveRetry` + `sessionAutosaveDeferredRetryPending`),
/// and the typing-activity timestamp (`recordTypingActivity` /
/// `lastTypingActivityAt`). The snapshot build/save itself stays app-side behind
/// ``SessionAutosaveScheduling`` because it reads the live window/tab tree and
/// writes the snapshot file.
///
/// **Isolation design.** `@MainActor`, not an actor. Every legacy entry point
/// already ran on the main actor: the `DispatchSource` timer fired on
/// `DispatchQueue.main`, `recordTypingActivity()` is called from the main-actor
/// key event monitor, and the deferred retry hopped back to `@MainActor` before
/// doing anything. The typing-quiet timestamp is read and compared inside one
/// main-actor turn, and the in-flight latch must be observed synchronously by
/// the next tick. Co-locating this state with its callers (the rule from
/// stage 3b: state lives where its callers live) turns every bridge into a
/// plain call; an actor here would only manufacture an isolation domain the
/// design immediately re-enters. The host is held weakly: `AppDelegate` owns
/// this scheduler, so a strong back-reference would be a retain cycle.
///
/// **Timer as a Clock task, not `DispatchSource`.** The repeating timer and the
/// one-shot deferred retry both become generation-guarded `Task`s that sleep on
/// an injected `any Clock<Duration>` (production passes `ContinuousClock`; tests
/// pass a manual clock). The legacy `DispatchSource` repeating timer with 8 s
/// period and 1 s leeway becomes a loop that sleeps the period then ticks; the
/// generation guard makes a stale fire after ``stop()`` a no-op without a
/// `Task.isCancelled` check, the same pattern as ``WorkspaceHandoffCoordinator``.
/// `Clock.sleep` is the injected, cancellable, testable replacement for the
/// banned `DispatchQueue.asyncAfter` the deferred retry used.
///
/// **Typing-quiet uptime source.** The legacy code timestamped typing with
/// `ProcessInfo.processInfo.systemUptime` (a monotonic clock unaffected by wall
/// clock changes) and compared the elapsed interval against the 0.65 s quiet
/// period. That monotonic reader is injected as ``uptime`` so tests can drive it
/// deterministically; production passes the `systemUptime` default. The
/// `any Clock<Duration>` and the uptime reader are intentionally separate: the
/// clock drives *delays*, the uptime reader measures *elapsed since last keypress*,
/// and conflating them would change which monotonic source the quiet-period math
/// reads.
@MainActor
public final class SessionAutosaveScheduler {
    /// The interval between autosave ticks. Legacy
    /// `SessionPersistencePolicy.autosaveInterval` (8 s).
    private let interval: Duration

    /// The quiet window after the last keypress during which a tick defers
    /// instead of saving. Legacy `AppDelegate.sessionAutosaveTypingQuietPeriod`
    /// (0.65 s), expressed in seconds to match the `systemUptime` math.
    private let typingQuietPeriod: TimeInterval

    /// Clock backing the repeating-timer and deferred-retry sleeps. Injected so
    /// tests drive cadence deterministically; production uses `ContinuousClock`.
    private let clock: any Clock<Duration>

    /// Monotonic uptime reader for the typing-quiet math. Injected so tests can
    /// advance "now" deterministically; production reads
    /// `ProcessInfo.processInfo.systemUptime`.
    private let uptime: @MainActor () -> TimeInterval

    /// Whether the autosave timer should arm at all. Production passes a check
    /// for `XCTest` (the legacy `guard !isRunningUnderXCTest(env)` in
    /// `startSessionAutosaveTimerIfNeeded`); tests that want to exercise the
    /// timer pass `false`.
    private let isAutosaveSuspended: @MainActor () -> Bool

    private weak var host: (any SessionAutosaveScheduling)?

    /// Monotonic uptime of the last recorded keypress, or 0 when none has been
    /// recorded. Legacy `AppDelegate.lastTypingActivityAt`.
    private var lastTypingActivityAt: TimeInterval = 0

    /// Whether an autosave tick is currently in flight (between the latch and
    /// the end of the async save body). Legacy
    /// `AppDelegate.sessionAutosaveTickInFlight`. A second tick that arrives
    /// while one is in flight is dropped, exactly as the legacy guard did.
    private var tickInFlight = false

    /// Whether a typing-quiet deferred retry is already scheduled. Legacy
    /// `AppDelegate.sessionAutosaveDeferredRetryPending`; makes the retry
    /// idempotent so repeated quiet-period ticks coalesce to one retry.
    private var deferredRetryPending = false

    /// The repeating-timer task, or nil when stopped. Legacy
    /// `AppDelegate.sessionAutosaveTimer` (a `DispatchSourceTimer`).
    private var timerTask: Task<Void, Never>?

    /// The pending deferred-retry task, kept so ``stop()`` can cancel it.
    private var deferredRetryTask: Task<Void, Never>?

    /// Monotonic generation; the timer and deferred-retry tasks capture their
    /// generation and no-op after a newer ``start()``/``stop()`` bumps it, so a
    /// stale fire is absorbed without a `Task.isCancelled` check.
    private var generation: UInt64 = 0

    /// Creates a scheduler.
    ///
    /// - Parameters:
    ///   - interval: the autosave period (default 8 s, the legacy
    ///     `SessionPersistencePolicy.autosaveInterval`).
    ///   - typingQuietPeriod: the post-keypress quiet window in seconds
    ///     (default 0.65 s, the legacy `sessionAutosaveTypingQuietPeriod`).
    ///   - clock: the clock backing the timer and deferred-retry sleeps
    ///     (default `ContinuousClock`).
    ///   - uptime: the monotonic uptime reader for the typing-quiet math
    ///     (default `ProcessInfo.processInfo.systemUptime`).
    ///   - isAutosaveSuspended: returns true when the timer must not arm
    ///     (default `false`; the app passes its `XCTest` check).
    public init(
        interval: Duration = .seconds(8),
        typingQuietPeriod: TimeInterval = 0.65,
        clock: any Clock<Duration> = ContinuousClock(),
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isAutosaveSuspended: @escaping @MainActor () -> Bool = { false }
    ) {
        self.interval = interval
        self.typingQuietPeriod = typingQuietPeriod
        self.clock = clock
        self.uptime = uptime
        self.isAutosaveSuspended = isAutosaveSuspended
    }

    /// Wires the app-side host that performs each save. Held weakly.
    public func attach(host: any SessionAutosaveScheduling) {
        self.host = host
    }

    /// Records a keypress timestamp so the next tick defers if it lands inside
    /// the typing-quiet window. Legacy `AppDelegate.recordTypingActivity()`.
    public func recordTypingActivity() {
        lastTypingActivityAt = uptime()
    }

    /// Arms the repeating autosave timer if not already armed and not
    /// suspended. Legacy `startSessionAutosaveTimerIfNeeded()`.
    public func start() {
        guard timerTask == nil else { return }
        guard !isAutosaveSuspended() else { return }
        generation &+= 1
        let armedGeneration = generation
        timerTask = Task { [weak self, clock, interval] in
            while !Task.isCancelled {
                try? await clock.sleep(for: interval, tolerance: .seconds(1))
                guard let self, self.generation == armedGeneration else { return }
                guard self.host?.isTerminatingApp == false else { continue }
                self.runTick(source: "timer")
            }
        }
    }

    /// Cancels the repeating timer and any pending retry, and clears the
    /// in-flight/retry latches. Legacy `stopSessionAutosaveTimer()`.
    public func stop() {
        generation &+= 1
        timerTask?.cancel()
        timerTask = nil
        deferredRetryTask?.cancel()
        deferredRetryTask = nil
        tickInFlight = false
        deferredRetryPending = false
    }

    /// Runs one autosave tick: the typing-quiet/in-flight gating, then the
    /// host's async save body under the in-flight latch. Legacy
    /// `runSessionAutosaveTick(source:)` + `finishSessionAutosaveTick`'s latch
    /// management.
    private func runTick(source: String) {
        guard host?.isTerminatingApp == false else { return }
        guard !tickInFlight else { return }
        if let remainingQuietPeriod = remainingTypingQuietPeriod() {
            scheduleDeferredRetry(after: remainingQuietPeriod)
            return
        }

        tickInFlight = true
        Task { [weak self] in
            await self?.host?.performScheduledAutosave(source: source)
            self?.tickInFlight = false
        }
    }

    /// The remaining quiet period if the last keypress is still inside the
    /// window, else nil. Legacy
    /// `remainingSessionAutosaveTypingQuietPeriod(nowUptime:)`.
    private func remainingTypingQuietPeriod() -> TimeInterval? {
        guard lastTypingActivityAt > 0 else { return nil }
        let elapsed = uptime() - lastTypingActivityAt
        guard elapsed < typingQuietPeriod else { return nil }
        return typingQuietPeriod - elapsed
    }

    /// Schedules one deferred retry after `delay` seconds, coalescing repeated
    /// quiet-period ticks. Legacy
    /// `scheduleDeferredSessionAutosaveRetry(after:)`.
    private func scheduleDeferredRetry(after delay: TimeInterval) {
        guard delay.isFinite, delay > 0 else { return }
        guard !deferredRetryPending else { return }
        deferredRetryPending = true
        let scheduledGeneration = generation
        deferredRetryTask = Task { [weak self, clock] in
            try? await clock.sleep(for: .seconds(delay))
            guard let self, self.generation == scheduledGeneration else { return }
            self.deferredRetryPending = false
            self.deferredRetryTask = nil
            self.runTick(source: "typingQuietRetry")
        }
    }
}
