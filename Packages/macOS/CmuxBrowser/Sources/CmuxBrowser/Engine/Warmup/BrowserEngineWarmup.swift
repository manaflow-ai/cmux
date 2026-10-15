public import Foundation

/// Starts a lazily loaded engine before its first page needs it, at a moment
/// the user is not typing or clicking.
///
/// Ported from cmux Next's `ChromiumWarmup`, with one Classic difference:
/// nothing happens at launch. While the default engine is WebKit and no
/// Chromium page exists, the app never maps the Chromium framework, never
/// starts it and never spawns a helper process. The app calls
/// ``engineLikely(_:)`` when a Chromium page becomes likely (a restored
/// Chromium page, a menu or palette entry that opens one, any browser page
/// while Chromium is the default, or switching the default to Chromium).
/// The warmup then maps the framework off the main thread and runs
/// ``BrowserEngineWarming/warmStart(reason:)`` once no key or mouse input
/// reached the app for ``BrowserEngineWarmupPolicy/idleInput`` and no menu
/// is tracking. Deadlines are one-shot and re-armed for the rest of the quiet
/// period after input; nothing polls. If the app never goes idle within
/// ``BrowserEngineWarmupPolicy/maxWait``, the warmup gives up and the first
/// page starts the engine itself. It runs at most once per process.
///
/// ```swift
/// let warmup = BrowserEngineWarmup(engine: chromiumProvider)
/// if session.containsChromiumPage { warmup.engineLikely(.restoredPage) }
/// ```
@MainActor
public final class BrowserEngineWarmup {
    /// Where the warmup is.
    public enum Phase: Equatable, Sendable {
        /// No page of the engine is likely yet.
        case idle
        /// Waiting for an idle moment.
        case waiting
        /// ``BrowserEngineWarming/warmStart(reason:)`` is running.
        case starting
        /// The engine started (by this warmup or by a page meanwhile).
        case started
        /// The app never went idle within the policy's limit, the warm start
        /// failed, or the warmup was stopped; the first page starts the engine.
        case abandoned
    }

    private let engine: any BrowserEngineWarming
    private let policy: BrowserEngineWarmupPolicy
    private let input: any BrowserEngineWarmupInputMonitoring
    private let idleTimer: any BrowserEngineWarmupTimer
    private let giveUpTimer: any BrowserEngineWarmupTimer
    private let now: @MainActor () -> TimeInterval
    private var lastInput: TimeInterval = 0
    private var waitsForMenuEnd = false

    /// Where the warmup is.
    public private(set) var phase: Phase = .idle
    /// Why the engine became likely; `nil` until ``engineLikely(_:)`` first
    /// takes effect.
    public private(set) var reason: BrowserEngineWarmupReason?

    /// Creates a warmup for one engine.
    /// - Parameters:
    ///   - engine: The engine to start.
    ///   - policy: Quiet period and give-up limit.
    ///   - input: Reports input and menu tracking while waiting.
    ///   - idleTimer: The quiet-period deadline.
    ///   - giveUpTimer: The give-up deadline.
    ///   - now: Seconds on a monotonic clock; system uptime by default.
    public init(
        engine: any BrowserEngineWarming,
        policy: BrowserEngineWarmupPolicy = BrowserEngineWarmupPolicy(),
        input: any BrowserEngineWarmupInputMonitoring = BrowserEngineWarmupAppKitInputMonitor(),
        idleTimer: any BrowserEngineWarmupTimer = BrowserEngineWarmupClockTimer(),
        giveUpTimer: any BrowserEngineWarmupTimer = BrowserEngineWarmupClockTimer(),
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.engine = engine
        self.policy = policy
        self.input = input
        self.idleTimer = idleTimer
        self.giveUpTimer = giveUpTimer
        self.now = now
    }

    /// A page of the engine is likely soon: map the framework now and start
    /// the engine at the next idle moment. Only the first call per process
    /// takes effect, and none does while the engine is unavailable or
    /// already running.
    /// - Parameter reason: Why a page is likely.
    public func engineLikely(_ reason: BrowserEngineWarmupReason) {
        guard self.reason == nil, phase == .idle, engine.availability.isAvailable else { return }
        guard !engine.isRunning else {
            phase = .started
            return
        }
        self.reason = reason
        phase = .waiting
        engine.preload()
        lastInput = now()
        input.start(
            onInput: { [weak self] in self?.noteInput() },
            onMenuTrackingEnd: { [weak self] in self?.menuTrackingEnded() }
        )
        armIdle(after: policy.idleInput)
        giveUpTimer.schedule(after: policy.maxWait) { [weak self] in self?.abandon() }
    }

    /// Ends the warmup for this process: a wait stops, and a later
    /// ``engineLikely(_:)`` does nothing. An engine start already under way
    /// finishes. The owner calls this before releasing a waiting warmup, so
    /// its input monitor is removed.
    public func stop() {
        switch phase {
        case .idle:
            phase = .abandoned
        case .waiting:
            finishWaiting()
            phase = .abandoned
        case .starting, .started, .abandoned:
            break
        }
    }

    /// Input while waiting pushes the start out by the rest of a new quiet
    /// period. A tracking loop that ended without a menu notification (a held
    /// button, a dragged scroller) re-arms the wait here.
    private func noteInput() {
        guard phase == .waiting else { return }
        lastInput = now()
        if waitsForMenuEnd, !input.isTrackingMenu {
            waitsForMenuEnd = false
            armIdle(after: policy.idleInput)
        }
    }

    private func armIdle(after delay: Duration) {
        idleTimer.schedule(after: delay) { [weak self] in self?.idleDeadline() }
    }

    private func idleDeadline() {
        guard phase == .waiting else { return }
        if engine.isRunning {
            finishWaiting()
            phase = .started
            return
        }
        if input.isTrackingMenu {
            waitsForMenuEnd = true
            return
        }
        let remaining = policy.idleInput.seconds - (now() - lastInput)
        guard remaining <= 0 else {
            armIdle(after: .nanoseconds(Int64((remaining * 1_000_000_000).rounded(.up))))
            return
        }
        start()
    }

    private func menuTrackingEnded() {
        guard phase == .waiting, waitsForMenuEnd else { return }
        waitsForMenuEnd = false
        lastInput = now()
        armIdle(after: policy.idleInput)
    }

    private func start() {
        guard let reason else { return }
        finishWaiting()
        phase = .starting
        let engine = engine
        // task-owner: one warm start per process; the engine owns its lifetime.
        Task { @MainActor [weak self] in
            await engine.warmStart(reason: reason)
            // A failed start leaves the engine to report its reason on the first page.
            self?.phase = engine.isRunning ? .started : .abandoned
        }
    }

    private func abandon() {
        guard phase == .waiting else { return }
        finishWaiting()
        phase = .abandoned
    }

    private func finishWaiting() {
        idleTimer.cancel()
        giveUpTimer.cancel()
        waitsForMenuEnd = false
        input.stop()
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
