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
