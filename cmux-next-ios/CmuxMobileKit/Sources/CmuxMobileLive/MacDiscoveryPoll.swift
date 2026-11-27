import Foundation

/// The account-wide Mac discovery loop (`GET /me/macs`) on an injected clock:
/// it looks, then waits `delay(waitingLooks:)` before the next look. Every 30 s while
/// the active team has an online Mac; while it has none, every 4 s for a minute
/// (someone opening cmux on a Mac), then doubling back to 30 s, not every 4 s for
/// ever. It never runs in the background (`pause`): the foreground (`resume`) looks at
/// once with the fast wait again.
///
/// It cannot feed itself (Leo, 2026-11-27: "The phone's retry loop can feed itself"):
/// - A look that fails (a timeout, a 5xx) is not "no Mac online": it leaves the fast
///   wait's count alone and backs off on its own, 4, 8, 16, 32, then every 60 s, each
///   jittered so phones and Macs that failed together do not retry together.
/// - A wake (a Mac's presence frame, a network change) looks soon but never restarts the
///   fast wait, never cancels a look already on the wire (it asks for one more after it),
///   and never looks sooner than `waitingPoll` after the last look started. Presence
///   frames wake it at most once per `idlePoll`, and not at all while looks fail: Macs
///   reconnecting to a struggling service send a frame each, and those must not shorten
///   the phone's backoff. Only a network change wakes a failing poll.
@MainActor
final class MacDiscoveryPoll {
    /// What one look found.
    enum Look: Sendable, Equatable {
        /// The active team has an online Mac.
        case online
        /// The service answered: the active team has no online Mac.
        case noneOnline
        /// The service did not answer (a timeout, a refused or failed request).
        case failed
    }

    /// Why something asks for a look now.
    enum Wake: Sendable {
        /// A Mac came or went (a presence frame).
        case macChanged
        /// The phone moved to another network.
        case network
    }

    /// How often discovery looks while the active team has no online Mac, and otherwise.
    nonisolated static let waitingPoll: Duration = .seconds(4)
    nonisolated static let idlePoll: Duration = .seconds(30)
    /// Looks `waitingPoll` apart before the wait starts doubling (one minute).
    nonisolated static let fastWaitingLooks = 15
    /// The longest wait after failed looks.
    nonisolated static let failedPollMax: Duration = .seconds(60)

    private let clock: any Clock<Duration>
    private let instants: ClockInstants
    /// Spreads a failure backoff wait (tests pass the identity).
    private let jitter: @Sendable (Duration) -> Duration
    /// One look, nil once its owner is gone.
    private var look: (@MainActor () async -> Look?)?
    private var task: Task<Void, Never>?
    private(set) var isStarted = false
    /// The app is in the background: no looks until `resume`.
    private(set) var isPaused = false
    /// A loop is running (looking or waiting for its next look).
    var isRunning: Bool { task != nil }
    /// Answered looks in a row that found no online Mac (the fast wait's count).
    private(set) var waitingLooks = 0
    /// Looks in a row that failed (the failure backoff's count).
    private(set) var failedLooks = 0
    /// A look is on the wire.
    private var looking = false
    /// A wake came while a look was on the wire: the next wait is at most `waitingPoll`.
    private var lookAgainSoon = false
    /// When the last look started.
    private var lastLookAt: ContinuousClock.Instant?
    /// When a Mac's presence frame last woke it.
    private var lastMacWakeAt: ContinuousClock.Instant?

    init(clock: any Clock<Duration>, jitter: @escaping @Sendable (Duration) -> Duration = MacDiscoveryPoll.randomJitter) {
        self.clock = clock
        instants = ClockInstants(clock)
        self.jitter = jitter
    }

    isolated deinit {
        task?.cancel()
    }

    /// Starts looking (once; a second call does nothing).
    func start(_ look: @escaping @MainActor () async -> Look?) {
        guard !isStarted else { return }
        isStarted = true
        self.look = look
        resetCounts()
        run(after: .zero)
    }

    /// Sign-out: no more looks until `start`.
    func stop() {
        isStarted = false
        look = nil
        cancel()
    }

    /// The app went to the background: the loop ends (and a `start` meanwhile waits).
    func pause() {
        isPaused = true
        cancel()
    }

    /// The app came to the foreground: look now, with the fast wait again.
    func resume() {
        isPaused = false
        resetCounts()
        run(after: .zero)
    }

    /// Something says a Mac changed (a presence frame, a network change): look soon,
    /// at most one look per `waitingPoll`. Nothing in the background.
    func wake(_ reason: Wake = .macChanged) {
        guard isStarted, !isPaused, look != nil else { return }
        let now = instants.now()
        if reason == .macChanged {
            // Looks are failing: only a new network can have fixed that.
            if failedLooks > 0 { return }
            // Macs flapping send a frame each: one extra look per `idlePoll` is enough.
            if let last = lastMacWakeAt, last.duration(to: now) < Self.idlePoll { return }
            lastMacWakeAt = now
        }
        if looking {
            lookAgainSoon = true
            return
        }
        let since = lastLookAt.map { $0.duration(to: now) } ?? Self.waitingPoll
        run(after: max(.zero, Self.waitingPoll - since))
    }

    private func resetCounts() {
        waitingLooks = 0
        failedLooks = 0
        lookAgainSoon = false
    }

    private func run(after firstWait: Duration) {
        cancel()
        guard isStarted, !isPaused, look != nil else { return }
        task = Task { [weak self, clock] in
            var wait = firstWait
            while !Task.isCancelled {
                if wait > .zero {
                    do { try await clock.sleep(for: wait) } catch { return }
                }
                guard let self, !Task.isCancelled else { return }
                guard let next = await self.lookOnce() else { return }
                wait = next
            }
        }
    }

    /// One look and the wait after it; nil when the loop should end.
    private func lookOnce() async -> Duration? {
        guard let look else { return nil }
        looking = true
        lastLookAt = instants.now()
        let found = await look()
        // A cancelled loop's look leaves the state to the loop that replaced it.
        guard !Task.isCancelled else { return nil }
        looking = false
        guard let found else { return nil }
        let soon = lookAgainSoon
        lookAgainSoon = false
        switch found {
        case .online:
            waitingLooks = 0
            failedLooks = 0
        case .noneOnline:
            waitingLooks += 1
            failedLooks = 0
        case .failed:
            failedLooks += 1
            return jitter(Self.failedDelay(failedLooks: failedLooks))
        }
        let wait = Self.delay(waitingLooks: waitingLooks)
        return soon ? min(wait, Self.waitingPoll) : wait
    }

    private func cancel() {
        task?.cancel()
        task = nil
        looking = false
    }

    /// The wait after a look; `waitingLooks` counts the looks in a row that found no online Mac.
    nonisolated static func delay(waitingLooks: Int) -> Duration {
        guard waitingLooks > 0 else { return idlePoll }
        guard waitingLooks > fastWaitingLooks else { return waitingPoll }
        let doublings = min(waitingLooks - fastWaitingLooks, 4)
        return min(idlePoll, waitingPoll * (1 << doublings))
    }

    /// The wait after `failedLooks` failed looks in a row: 4, 8, 16, 32, then 60 s.
    nonisolated static func failedDelay(failedLooks: Int) -> Duration {
        guard failedLooks > 0 else { return .zero }
        let doublings = min(failedLooks - 1, 5)
        return min(failedPollMax, waitingPoll * (1 << doublings))
    }

    /// 80% to 120% of `wait`.
    nonisolated static func randomJitter(_ wait: Duration) -> Duration {
        wait * Double.random(in: 0.8...1.2)
    }
}
