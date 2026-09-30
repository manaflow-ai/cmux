import CmuxNextWakeups
import Testing
@testable import CmuxNextApp

@MainActor
private final class SilentLink: FrameLink {
    var isPaused = true
    func invalidate() {}
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameBatcherTests {
    /// Regression (state-audit D4): the store drain, pane presentation, and
    /// the CLI work queue all wait for a frame. A link that stops firing
    /// (displays asleep, the link's screen unplugged) froze daemon updates
    /// and made every mutating CLI request time out.
    @Test func workStillRunsWhenTheLinkNeverFires() async {
        let clock = ManualClock()
        let scheduler = FrameScheduler.testing(clock: clock, ledger: WakeupLedger(), makeLink: { _ in SilentLink() })
        let batcher = FrameBatcher(owner: "test", scheduler: scheduler)
        let (ran, signal) = AsyncStream.makeStream(of: Void.self)
        batcher.enqueue { signal.yield() }
        // The stall deadline is armed; no frame comes; its time passes.
        await clock.sleepers()
        clock.advance(by: FrameScheduler.stallTimeout)
        var iterator = ran.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test func aFrameRunsPendingWorkAndPausesTheLink() {
        let link = SilentLink()
        let scheduler = FrameScheduler.testing(ledger: WakeupLedger(), makeLink: { _ in link })
        let batcher = FrameBatcher(owner: "test", scheduler: scheduler)
        var count = 0
        batcher.enqueue { count += 1 }
        batcher.enqueue { count += 1 }
        #expect(!link.isPaused)
        #expect(scheduler.activeClients == ["test"])
        scheduler.frameDidFire()
        #expect(count == 2)
        #expect(!scheduler.hasLink)
        #expect(scheduler.activeClients.isEmpty)
    }

    @Test func workEnqueuedDuringAFrameRunsNextFrame() {
        let link = SilentLink()
        let scheduler = FrameScheduler.testing(ledger: WakeupLedger(), makeLink: { _ in link })
        let batcher = FrameBatcher(owner: "test", scheduler: scheduler)
        var order: [Int] = []
        batcher.enqueue {
            order.append(1)
            batcher.enqueue { order.append(2) }
        }
        scheduler.frameDidFire()
        #expect(order == [1])
        #expect(!link.isPaused)
        scheduler.frameDidFire()
        #expect(order == [1, 2])
        #expect(!scheduler.hasLink)
    }
}
