import Testing
@testable import CmuxNextWakeups

@MainActor
private final class FakeLink: FrameLink {
    var isPaused = true
    var invalidated = false
    func invalidate() { invalidated = true }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSchedulerTests {
    @Test func linkRunsOnlyWhileAClientIsActive() {
        let link = FakeLink()
        let scheduler = FrameScheduler.testing(ledger: WakeupLedger(), makeLink: { _ in link })
        var remaining = 3
        let client = FrameClient(owner: "spring", on: scheduler) { _ in
            remaining -= 1
            return remaining > 0
        }
        #expect(link.isPaused)
        client.activate()
        #expect(!link.isPaused)
        #expect(scheduler.activeClients == ["spring"])
        scheduler.frameDidFire()
        scheduler.frameDidFire()
        #expect(!link.isPaused)
        scheduler.frameDidFire()
        #expect(remaining == 0)
        #expect(link.invalidated)
        #expect(!scheduler.hasLink)
        #expect(scheduler.activeClients.isEmpty)
        #expect(!client.isActive)
    }

    @Test func deactivatingTheLastClientPausesTheLink() {
        let link = FakeLink()
        let scheduler = FrameScheduler.testing(ledger: WakeupLedger(), makeLink: { _ in link })
        let a = FrameClient(owner: "a", on: scheduler) { _ in true }
        let b = FrameClient(owner: "b", on: scheduler) { _ in true }
        a.activate()
        b.activate()
        #expect(scheduler.activeClients == ["a", "b"])
        a.deactivate()
        #expect(!link.isPaused)
        b.deactivate()
        #expect(link.invalidated)
        #expect(!scheduler.hasLink)
    }

    @Test func framesAreCountedPerClientInTheLedger() {
        let ledger = WakeupLedger()
        let scheduler = FrameScheduler.testing(ledger: ledger, makeLink: { _ in FakeLink() })
        let client = FrameClient(owner: "autoscroll", on: scheduler) { _ in true }
        client.activate()
        for _ in 0..<5 { scheduler.frameDidFire() }
        #expect(ledger.snapshot().first { $0.owner == "autoscroll" }?.count == 5)
        client.deactivate()
    }

    /// Regression (state-audit D4): a link that stops firing (displays
    /// asleep, screen unplugged) must not freeze clients such as the daemon
    /// store drain.
    @Test func clientsStillTickWhenTheLinkNeverFires() async {
        let clock = ManualClock()
        let scheduler = FrameScheduler.testing(clock: clock, ledger: WakeupLedger(), makeLink: { _ in FakeLink() })
        var ran = false
        let client = FrameClient(owner: "drain", on: scheduler) { _ in
            ran = true
            return false
        }
        client.activate()
        for _ in 0..<10_000 where clock.sleeperCount == 0 { await Task.yield() }
        clock.advance(by: FrameScheduler.stallTimeout)
        for _ in 0..<10_000 where !ran { await Task.yield() }
        #expect(ran)
    }

    @Test func repeatedStallsRebuildTheLink() async {
        let clock = ManualClock()
        var links: [FakeLink] = []
        let scheduler = FrameScheduler.testing(clock: clock, ledger: WakeupLedger(), makeLink: { _ in
            let link = FakeLink()
            links.append(link)
            return link
        })
        var ticks = 0
        let client = FrameClient(owner: "drain", on: scheduler) { _ in
            ticks += 1
            return ticks < FrameScheduler.stallsBeforeRebuild + 1
        }
        client.activate()
        for _ in 0..<(FrameScheduler.stallsBeforeRebuild + 1) {
            for _ in 0..<10_000 where clock.sleeperCount == 0 { await Task.yield() }
            let before = ticks
            clock.advance(by: FrameScheduler.stallTimeout)
            for _ in 0..<10_000 where ticks == before { await Task.yield() }
        }
        #expect(!client.isActive)
        #expect(links.count == 2)
        #expect(links.first?.invalidated == true)
    }
}
