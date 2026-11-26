import Foundation
import Observation
import Testing
@testable import CmuxMobileModel

/// ``BoundedWait/observing(while:)``: a wait for an observed state that a change ends, and
/// that cancellation ends at once with no change at all (review on cmux#50367: a wait
/// ``BoundedWait/run(_:)`` gave up on stayed suspended until the next change).
@MainActor
@Suite struct BoundedWaitObservingTests {
    @Observable @MainActor final class Flag {
        var on = true
    }

    @Test func aChangeEndsTheWait() async {
        let flag = Flag()
        let waiter = Task { @MainActor in await BoundedWait.observing { flag.on } }
        await Task.yield()
        flag.on = false
        await waiter.value
        #expect(!flag.on)
    }

    @Test func cancellationEndsTheWaitWithNoChange() async {
        let flag = Flag()
        let waiter = Task { @MainActor in await BoundedWait.observing { flag.on } }
        await Task.yield()
        waiter.cancel()
        await waiter.value
        #expect(flag.on, "nothing changed; cancellation alone ended it")
    }

    @Test func aBoundedRunThatGivesUpLeavesNoWaitBehind() async {
        let flag = Flag()
        let ended = Flag()
        let finished = await BoundedWait(.milliseconds(50)).run { @MainActor in
            await BoundedWait.observing { flag.on }
            ended.on = false
        }
        #expect(!finished)
        // The worker was cancelled at the limit; its wait ends without any change to `flag`.
        let workerEnded = await BoundedWait(.seconds(10)).run { @MainActor in
            await BoundedWait.observing { ended.on }
        }
        #expect(workerEnded)
        #expect(flag.on)
    }

    @Test func alreadyDoneReturnsAtOnce() async {
        let flag = Flag()
        flag.on = false
        await BoundedWait.observing { flag.on }
    }
}
