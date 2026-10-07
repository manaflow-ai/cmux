import os

/// A test `Clock` that only moves when `advance(by:)` is called.
public final class ManualClock: Clock, Sendable {
    public struct Instant: InstantProtocol {
        public var offset: Duration

        public init(offset: Duration) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
        var cancelled: Set<UInt64> = []
        var sleeperWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    // carve-out: `Clock.now` is synchronous, so an actor cannot hold this state.
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }

    public var minimumResolution: Duration { .nanoseconds(1) }

    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case cancel, resume, wait([CheckedContinuation<Void, Never>]) }
                let action = state.withLock { state -> Action in
                    if state.cancelled.remove(id) != nil { return .cancel }
                    if deadline <= state.now { return .resume }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .wait(Self.takeReadyWaiters(&state))
                }
                switch action {
                case .cancel: continuation.resume(throwing: CancellationError())
                case .resume: continuation.resume()
                case let .wait(waiters): for waiter in waiters { waiter.resume() }
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                if let sleeper = state.sleepers.removeValue(forKey: id) { return sleeper }
                state.cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline passed.
    public func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let ready = state.sleepers.filter { $0.value.deadline <= now }
            for id in ready.keys { state.sleepers[id] = nil }
            return ready.values.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Returns once at least `count` sleepers are waiting.
    public func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.sleepers.count >= count { return true }
                state.sleeperWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private static func takeReadyWaiters(_ state: inout State) -> [CheckedContinuation<Void, Never>] {
        let count = state.sleepers.count
        let ready = state.sleeperWaiters.filter { $0.count <= count }.map(\.continuation)
        state.sleeperWaiters.removeAll { $0.count <= count }
        return ready
    }
}
