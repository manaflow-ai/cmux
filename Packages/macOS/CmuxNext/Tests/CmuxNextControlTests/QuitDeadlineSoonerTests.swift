import CmuxNextCompat
import CmuxNextControl
import Foundation
import Testing

/// `QuitDeadline.endSooner` (the engine stop's bound, cmuxterm-hq#11994): it moves an armed deadline
/// earlier, never later, and the end runs once whichever limit passes first. No clock decides these
/// tests: each limit's wait is recorded and the test passes it by hand (``DeadlineWaits``).
@Suite(.serialized)
struct QuitDeadlineSoonerTests {
    @Test func aSoonerEndAddsAShorterWaitAndTheEndRunsOnce() {
        let waits = DeadlineWaits()
        let deadline = waits.deadline()
        deadline.arm(after: .seconds(4))
        deadline.endSooner(after: .seconds(1), reason: "a sooner test")
        #expect(waits.limits() == [.seconds(4), .seconds(1)])
        waits.pass(.seconds(1))
        #expect(waits.ends() == 1, "the sooner limit did not end the quit")
        waits.pass(.seconds(4))
        #expect(waits.ends() == 1, "the end ran again when the first limit passed")
    }

    @Test func aLaterEndNeverMovesItLater() {
        let waits = DeadlineWaits()
        let deadline = waits.deadline()
        deadline.arm(after: .seconds(1))
        deadline.endSooner(after: .seconds(5), reason: "a later test")
        #expect(waits.limits() == [.seconds(1)], "a later limit was scheduled")
    }

    @Test func aSoonerEndArmsAnUnarmedDeadline() {
        let waits = DeadlineWaits()
        let deadline = waits.deadline()
        #expect(deadline.timeLeft() == nil)
        deadline.endSooner(after: .seconds(1), reason: "a test")
        #expect(deadline.timeLeft() != nil)
        deadline.arm(after: .seconds(5))
        #expect(waits.limits() == [.seconds(1)], "arming after a sooner end scheduled another limit")
        waits.pass(.seconds(1))
        #expect(waits.ends() == 1)
    }
}

/// A ``QuitDeadline``'s limits, recorded instead of waited out; ``pass(_:)`` ends one's wait. Its ends counted.
nonisolated final class DeadlineWaits: Sendable {
    private let state = Mutex<(waits: [(Duration, @Sendable () -> Void)], ends: Int)>(([], 0))

    func deadline() -> QuitDeadline {
        QuitDeadline(reason: "a test", end: { self.state.withLock { $0.ends += 1 } },
                     schedule: { limit, fire in self.state.withLock { $0.waits.append((limit, fire)) } })
    }

    func limits() -> [Duration] { state.withLock { $0.waits.map(\.0) } }

    func ends() -> Int { state.withLock { $0.ends } }

    /// Every wait of `limit` passes now.
    func pass(_ limit: Duration) {
        let fires = state.withLock { $0.waits.filter { $0.0 == limit }.map(\.1) }
        for fire in fires { fire() }
    }
}
