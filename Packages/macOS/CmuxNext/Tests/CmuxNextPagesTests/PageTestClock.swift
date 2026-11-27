import Foundation

/// A clock for the Chromium page deadline: ``immediate`` ends every sleep on the next task turn,
/// ``never`` ends a sleep only when its task is cancelled.
nonisolated struct PageTestClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    static let immediate = PageTestClock(fires: true)
    static let never = PageTestClock(fires: false)

    let fires: Bool

    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        if fires {
            await Task.yield()
        } else {
            // A stream nobody yields to: iterating it ends only when the task is cancelled. The
            // continuation is held to the end, since dropping it would finish the stream.
            let (pending, continuation) = AsyncStream<Void>.makeStream()
            for await _ in pending {}
            withExtendedLifetime(continuation) {}
        }
        try Task.checkCancellation()
    }
}
