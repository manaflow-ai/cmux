import Foundation

/// The account-wide Mac discovery loop (`GET /me/macs`) on an injected clock:
/// it looks, then waits `delay(waitingLooks:)` before the next look. Every 30 s while
/// the active team has an online Mac; while it has none, every 4 s for a minute
/// (someone opening cmux on a Mac), then doubling back to 30 s, not every 4 s for
/// ever. It never runs in the background (`pause`): the foreground (`resume`) and a
/// Mac's presence change or a network change (`wake`) look at once.
@MainActor
final class MacDiscoveryPoll {
    /// How often discovery looks while the active team has no online Mac, and otherwise.
    nonisolated static let waitingPoll: Duration = .seconds(4)
    nonisolated static let idlePoll: Duration = .seconds(30)
    /// Looks `waitingPoll` apart before the wait starts doubling (one minute).
    nonisolated static let fastWaitingLooks = 15

    private let clock: any Clock<Duration>
    /// One look; says whether the active team has an online Mac, nil once its owner is gone.
    private var look: (@MainActor () async -> Bool?)?
    private var task: Task<Void, Never>?
    private(set) var isStarted = false
    /// The app is in the background: no looks until `resume`.
    private(set) var isPaused = false
    /// A loop is running (looking or waiting for its next look).
    var isRunning: Bool { task != nil }

    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    isolated deinit {
        task?.cancel()
    }

    /// Starts looking (once; a second call does nothing).
    func start(_ look: @escaping @MainActor () async -> Bool?) {
        guard !isStarted else { return }
        isStarted = true
        self.look = look
        run()
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
        run()
    }

    /// Something says a Mac changed (a presence frame, a network change): look now,
    /// with the fast wait again. Nothing in the background.
    func wake() {
        run()
    }

    private func run() {
        cancel()
        guard isStarted, !isPaused, let look else { return }
        task = Task { [weak self, clock] in
            var waitingLooks = 0
            while !Task.isCancelled {
                guard let online = await look() else { return }
                guard !Task.isCancelled else { return }
                waitingLooks = online ? 0 : waitingLooks + 1
                do { try await clock.sleep(for: Self.delay(waitingLooks: waitingLooks)) } catch { return }
                guard self != nil else { return }
            }
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
    }

    /// The wait after a look; `waitingLooks` counts the looks in a row that found no online Mac.
    nonisolated static func delay(waitingLooks: Int) -> Duration {
        guard waitingLooks > 0 else { return idlePoll }
        guard waitingLooks > fastWaitingLooks else { return waitingPoll }
        let doublings = min(waitingLooks - fastWaitingLooks, 4)
        return min(idlePoll, waitingPoll * (1 << doublings))
    }
}
