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
    @Test func workStillRunsWhenTheLinkNeverFires() async throws {
        let link = SilentLink()
        let scheduler = DisplayLinkFrameScheduler(makeLink: { _ in link })
        var ran = false
        scheduler.scheduleFrame { ran = true }
        let deadline = ContinuousClock.now + .seconds(2)
        while !ran, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ran)
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
    @Test func repeatedStallsRebuildTheLink() async throws {
        var links: [SilentLinkBox] = []
        let scheduler = DisplayLinkFrameScheduler(makeLink: { _ in
            let box = SilentLinkBox()
            links.append(box)
            return box
        })
        for _ in 0..<DisplayLinkFrameScheduler.stallsBeforeRebuild {
            var ran = false
            scheduler.scheduleFrame { ran = true }
            while !ran { try await Task.sleep(for: .milliseconds(10)) }
        }
        var ranAgain = false
        scheduler.scheduleFrame { ranAgain = true }
        while !ranAgain { try await Task.sleep(for: .milliseconds(10)) }
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
