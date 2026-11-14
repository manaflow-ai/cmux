import Foundation

/// The account-wide Mac discovery loop (`GET /me/macs`) on an injected clock:
/// it looks, then waits `delay(waitingLooks:)` before the next look.
@MainActor
final class MacDiscoveryPoll {
    /// How often discovery looks while the active team has no online Mac, and otherwise.
    nonisolated static let waitingPoll: Duration = .seconds(4)
    nonisolated static let idlePoll: Duration = .seconds(30)

    private let clock: any Clock<Duration>
    /// One look; says whether the active team has an online Mac, nil once its owner is gone.
    private var look: (@MainActor () async -> Bool?)?
    private var task: Task<Void, Never>?
    private(set) var isStarted = false
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

    /// The app went to the background.
    func pause() {}

    /// The app came to the foreground: look now.
    func resume() {
        run()
    }

    /// Something says a Mac changed (a presence frame, a network change): look now.
    func wake() {
        run()
    }

    private func run() {
        cancel()
        guard isStarted, let look else { return }
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
        waitingLooks > 0 ? waitingPoll : idlePoll
    }
}
