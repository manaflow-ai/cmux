/// A clock whose `now` never moves. Each sleep reports the wait and the
/// tolerance its caller asked for on `wakes`, then either returns at once (the
/// deadline passed) or stays suspended until its task is cancelled.
struct WakeRecordingClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    struct Wake: Equatable, Sendable {
        var wait: Swift.Duration
        var tolerance: Swift.Duration?
    }

    enum Firing: Sendable {
        case firesAtOnce
        case neverFires
    }

    let wakes: AsyncStream<Wake>
    private let recorder: AsyncStream<Wake>.Continuation
    private let firing: Firing

    init(_ firing: Firing) {
        (wakes, recorder) = AsyncStream<Wake>.makeStream()
        self.firing = firing
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        recorder.yield(Wake(wait: deadline.offset, tolerance: tolerance))
        switch firing {
        case .firesAtOnce:
            return
        case .neverFires:
            // An AsyncStream iteration ends when its task is cancelled; nothing
            // ever yields to this one, so it parks the sleep without a timer.
            let (parked, keepOpen) = AsyncStream<Never>.makeStream()
            for await _ in parked {}
            withExtendedLifetime(keepOpen) {}
            throw CancellationError()
        }
    }

    /// The next `count` wakes, in the order the sleeps started.
    func nextWakes(_ count: Int) async -> [Wake] {
        var recorded: [Wake] = []
        for await wake in wakes {
            recorded.append(wake)
            if recorded.count == count { break }
        }
        return recorded
    }
}
