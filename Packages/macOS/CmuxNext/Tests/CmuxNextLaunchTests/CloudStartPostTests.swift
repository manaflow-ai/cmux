import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The launch's Cloud start (p08-startup task 020): never before the first frame; after startup by
/// default; right after the first frame, or in the next frame once it passed, on a visible need.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CloudStartPostTests {
    @Test func aNeedBeforeTheFirstFrameStartsCloudRightAfterIt() {
        let s = StartupTestScheduler(), starts = StartCount()
        let post = CloudStartPost(startup: s.startup, start: { starts.count += 1 })
        post.post()
        post.need()
        s.fire()
        #expect(starts.count == 0, "nothing starts before the first frame")
        s.startup.firstFrameCommitted()
        s.fire()
        #expect(starts.count == 1, "the needed machine connects right after the first frame")
        #expect(s.startup.completion == nil, "it did not wait for startup to complete")
    }

    /// The window restore makes its saved windows after the first frame: a need then starts Cloud in
    /// the next frame, never at the end of startup (which those same windows hold open).
    @Test func aNeedAfterTheFirstFrameStartsCloudInTheNextFrame() {
        let s = StartupTestScheduler(), starts = StartCount()
        let post = CloudStartPost(startup: s.startup, start: { starts.count += 1 })
        post.post()
        s.startup.firstFrameCommitted()
        s.fire()
        #expect(starts.count == 0, "the launch window is local: no need yet")
        post.need()
        s.fire()
        #expect(starts.count == 1, "a restored Cloud window's need starts Cloud in the next frame")
        #expect(s.startup.completion == nil, "before startup completes")
        post.need()
        s.fire()
        #expect(starts.count == 1, "one need post per launch")
    }

    @Test func withNoNeedCloudStartsAfterStartup() {
        let s = StartupTestScheduler(), starts = StartCount()
        CloudStartPost(startup: s.startup, start: { starts.count += 1 }).post()
        s.startup.firstFrameCommitted()
        s.fire()
        #expect(starts.count == 0, "a local launch keeps Cloud out of the first frames")
        s.startup.finishRegistration()
        s.hand.drain()
        #expect(s.startup.completion != nil)
        s.fire()
        #expect(starts.count == 1, "one idle frame after completion")
        for _ in 0..<3 { s.fire() }
        #expect(starts.count == 1, "started once")
    }

    @Test func quitNeverStartsCloud() {
        let s = StartupTestScheduler(), starts = StartCount()
        let post = CloudStartPost(startup: s.startup, start: { starts.count += 1 })
        post.post()
        s.startup.beginQuit()
        post.need()
        s.startup.firstFrameCommitted()
        s.startup.finishRegistration()
        s.hand.drain()
        for _ in 0..<3 { s.fire() }
        #expect(starts.count == 0)
    }
}

@MainActor
private final class StartCount {
    var count = 0
}
