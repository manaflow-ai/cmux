import Testing
@testable import CmuxNextApp

@MainActor
private final class SilentLink: FrameLink {
    var isPaused = true
    var invalidated = false
    func invalidate() { invalidated = true }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSchedulerTests {
    /// Regression: the store drain, pane presentation, and the CLI work
    /// queue all wait for a display-link tick. A link that stops firing
    /// (displays asleep, the link's screen unplugged) froze daemon updates
    /// and made every mutating CLI request time out.
    @Test func workStillRunsWhenTheLinkNeverFires() async {
        let link = SilentLink()
        let clock = ManualClock()
        let scheduler = DisplayLinkFrameScheduler(clock: clock, makeLink: { _ in link })
        let (ran, signal) = AsyncStream.makeStream(of: Void.self)
        scheduler.scheduleFrame { signal.yield() }
        // The stall deadline is armed; no frame comes; its time passes.
        await clock.sleepers()
        clock.advance(by: DisplayLinkFrameScheduler.stallTimeout)
        var iterator = ran.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test func aTickRunsPendingWorkAndPausesTheLink() async throws {
        let link = SilentLink()
        let scheduler = DisplayLinkFrameScheduler(makeLink: { _ in link })
        var count = 0
        scheduler.scheduleFrame { count += 1 }
        scheduler.scheduleFrame { count += 1 }
        while link.isPaused { await Task.yield() }
        scheduler.frameDidFire()
        #expect(count == 2)
        #expect(link.isPaused)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSchedulerStallTests {
    @Test func repeatedStallsRebuildTheLink() async {
        var links: [SilentLinkBox] = []
        let clock = ManualClock()
        let scheduler = DisplayLinkFrameScheduler(clock: clock, makeLink: { _ in
            let box = SilentLinkBox()
            links.append(box)
            return box
        })
        let (ran, signal) = AsyncStream.makeStream(of: Void.self)
        var iterator = ran.makeAsyncIterator()
        for _ in 0...DisplayLinkFrameScheduler.stallsBeforeRebuild {
            scheduler.scheduleFrame { signal.yield() }
            await clock.sleepers()
            clock.advance(by: DisplayLinkFrameScheduler.stallTimeout)
            _ = await iterator.next()
        }
        #expect(links.count == 2)
        #expect(links.first?.invalidated == true)
    }
}

@MainActor
private final class SilentLinkBox: FrameLink {
    var isPaused = true
    var invalidated = false
    func invalidate() { invalidated = true }
}
