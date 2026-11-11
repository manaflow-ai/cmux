import Foundation
import Testing
@testable import CmuxMobileModel

/// Review m4: sign-out waits for the Mac's unpair at most 3 s, also when
/// the unpair is stuck in a wait that ignores cancellation.
///
/// The limit runs on a `RecordedClock`, so the test checks the deadline the
/// wait slept until, not how long a loaded runner took to get there.
@Suite struct BoundedWaitTests {
    /// A wait that never ends and ignores cancellation.
    final class Stuck: @unchecked Sendable {
        let lock = NSLock()
        var held: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { c in lock.withLock { held = c } } }
        func release() { lock.withLock { held }?.resume() }
    }

    @Test func returnsAtTheLimitWhenTheWorkIgnoresCancellation() async {
        let stuck = Stuck()
        let clock = RecordedClock()
        let finished = await BoundedWait(.milliseconds(100)).run(on: clock) { await stuck.wait() }
        #expect(!finished)
        // It gave up at the limit, 100 ms after it started, and no later.
        #expect(clock.sleptUntil == [RecordedClock.at(.milliseconds(100))])
        #expect(clock.now == RecordedClock.at(.milliseconds(100)))
        stuck.release()
    }

    @Test func returnsAsSoonAsTheWorkEnds() async {
        let finished = await BoundedWait(.seconds(30)).run {}
        #expect(finished)
    }
}

/// A clock that moves only when told to. Each sleep records its deadline and
/// ends at once: a cancelled sleep throws, as a real clock's does, and any other
/// sleep moves the clock to its deadline when that is later. No wall time is
/// read, so a timing test on it cannot flake under load. (The same clock as
/// CmuxMobileWorkspacesTests' RetryButtonHoldTests.)
final class RecordedClock: Clock, @unchecked Sendable { // crash-allow: lock-guarded test clock
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    static func at(_ offset: Duration) -> Instant { Instant(offset: offset) }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var deadlines: [Instant] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    var sleptUntil: [Instant] { lock.withLock { deadlines } }

    func advance(by duration: Duration) { lock.withLock { current = current.advanced(by: duration) } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        lock.withLock { deadlines.append(deadline) }
        try Task.checkCancellation()
        lock.withLock { if current < deadline { current = deadline } }
    }
}
