import Foundation

/// The account-wide Mac discovery loop (`GET /me/macs`) on an injected clock:
/// it looks, then waits before the next look. Every 30 s while the active team has
/// an online Mac; while it has none, every 4 s for a minute (someone opening cmux on
/// a Mac), then doubling back to 30 s, not every 4 s for ever. It never runs in the
/// background (`pause`): the foreground (`resume`) looks at once with the fast wait again.
///
/// Nothing the loop causes feeds it (Leo, 2026-11-27, on the phone's retry loop: "That's
/// a loop that keeps going once it starts"):
/// - A look that failed (a timeout, a 5xx) says nothing about the Macs: it does not count
///   as "no online Mac", and the next look backs off 8, 16, 32, then every 60 s until one answers.
/// - A Mac's presence change or a network change (`wake`) looks now, but keeps the backoff:
///   it never restarts the fast minute, and wakes in a row are spaced 4, 8, 16, then 30 s
///   apart (three Macs reconnecting over and over send a presence frame each time).
@MainActor
final class MacDiscoveryPoll {
    /// What one look found.
    enum Look: Equatable {
        /// The active team has an online Mac.
        case online
        /// The service answered and the active team has no online Mac.
        case noMac
        /// The service did not answer (timeout, transport error, 5xx).
        case failed
    }

    /// How often discovery looks while the active team has no online Mac, and otherwise.
    nonisolated static let waitingPoll: Duration = .seconds(4)
    nonisolated static let idlePoll: Duration = .seconds(30)
    /// The longest wait after failed looks in a row.
    nonisolated static let failedPoll: Duration = .seconds(60)
    /// Looks `waitingPoll` apart before the wait starts doubling (one minute).
    nonisolated static let fastWaitingLooks = 15

    private let clock: any Clock<Duration>
    /// One look; nil once its owner is gone.
    private var look: (@MainActor () async -> Look?)?
    private var task: Task<Void, Never>?
    private(set) var isStarted = false
    /// The app is in the background: no looks until `resume`.
    private(set) var isPaused = false
    /// A loop is running (looking or waiting for its next look).
    var isRunning: Bool { task != nil }

    /// Answered looks in a row that found no online Mac (the fast minute, then the doubling).
    private(set) var waitingLooks = 0
    /// Failed looks in a row.
    private(set) var failedLooks = 0
    /// Looks in a row that a wake started (their spacing doubles).
    private(set) var wakeLooks = 0
    private enum Phase { case idle, looking, spacing, waiting }
    /// Where the loop is: a wake while it looks or right after a look waits for the spacing.
    private var phase: Phase = .idle
    /// A wake came while the loop was looking or spacing: look as soon as the spacing ends.
    private var wakePending = false

    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    isolated deinit {
        task?.cancel()
    }

    /// Starts looking (once; a second call does nothing).
    func start(_ look: @escaping @MainActor () async -> Look?) {
        guard !isStarted else { return }
        isStarted = true
        self.look = look
        run(byWake: false)
    }

    /// Sign-out: no more looks until `start`.
    func stop() {
        isStarted = false
        look = nil
        cancel()
        waitingLooks = 0
        failedLooks = 0
        wakeLooks = 0
    }

    /// The app went to the background: the loop ends (and a `start` meanwhile waits).
    func pause() {
        isPaused = true
        cancel()
    }

    /// The app came to the foreground: look now, with the fast wait again (the person
    /// opened the app; a failing service keeps its backoff until it answers).
    func resume() {
        isPaused = false
        waitingLooks = 0
        wakeLooks = 0
        run(byWake: false)
    }

    /// Something says a Mac changed (a presence frame, a network change): look now, or
    /// once the spacing since the last look ends. The backoff stays. Nothing in the background.
    func wake() {
        guard isStarted, !isPaused, look != nil else { return }
        switch phase {
        case .idle, .waiting: run(byWake: true)
        case .looking, .spacing: wakePending = true
        }
    }

    private func run(byWake: Bool) {
        cancel()
        guard isStarted, !isPaused, look != nil else { return }
        task = Task { [weak self, clock] in
            var byWake = byWake
            defer { if !Task.isCancelled { self?.phase = .idle } }
            while !Task.isCancelled {
                guard let look = self?.beginLook() else { return }
                guard let result = await look() else { return }
                guard !Task.isCancelled, let wait = self?.finishLook(result, byWake: byWake) else { return }
                do { try await clock.sleep(for: wait.spacing) } catch { return }
                guard !Task.isCancelled, let wakePending = self?.endSpacing() else { return }
                byWake = wakePending
                if !wakePending, wait.rest > .zero {
                    do { try await clock.sleep(for: wait.rest) } catch { return }
                }
            }
        }
    }

    private func beginLook() -> (@MainActor () async -> Look?)? {
        phase = .looking
        wakePending = false
        return look
    }

    /// The spacing after a look ended: says whether a wake came meanwhile (look now),
    /// else the loop waits the rest, which a wake cuts short.
    private func endSpacing() -> Bool {
        if wakePending { return true }
        phase = .waiting
        return false
    }

    /// Counts one look; returns the wait a wake cannot cut short and the rest of the wait.
    private func finishLook(_ result: Look, byWake: Bool) -> (spacing: Duration, rest: Duration) {
        switch result {
        case .online: waitingLooks = 0; failedLooks = 0
        case .noMac: waitingLooks += 1; failedLooks = 0
        case .failed: failedLooks += 1
        }
        wakeLooks = byWake ? wakeLooks + 1 : 0
        phase = .spacing
        let delay = Self.delay(waitingLooks: waitingLooks, failedLooks: failedLooks)
        let spacing = min(delay, Self.wakeSpacing(wakeLooks: wakeLooks, failedLooks: failedLooks))
        return (spacing: spacing, rest: delay - spacing)
    }

    private func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        wakePending = false
    }

    /// The wait after a look; `waitingLooks` counts the answered looks in a row that found
    /// no online Mac, `failedLooks` the failed looks in a row (they win).
    nonisolated static func delay(waitingLooks: Int, failedLooks: Int = 0) -> Duration {
        if failedLooks > 0 { return min(failedPoll, waitingPoll * (1 << min(failedLooks, 4))) }
        guard waitingLooks > 0 else { return idlePoll }
        guard waitingLooks > fastWaitingLooks else { return waitingPoll }
        let doublings = min(waitingLooks - fastWaitingLooks, 4)
        return min(idlePoll, waitingPoll * (1 << doublings))
    }

    /// The least time from a look to the next one a wake starts: 4 s, doubling to 30 s over
    /// wakes in a row, and no sooner than a failing service's backoff.
    nonisolated static func wakeSpacing(wakeLooks: Int, failedLooks: Int = 0) -> Duration {
        let spacing = min(idlePoll, waitingPoll * (1 << min(max(wakeLooks - 1, 0), 3)))
        return failedLooks > 0 ? max(spacing, delay(waitingLooks: 0, failedLooks: failedLooks)) : spacing
    }
}
