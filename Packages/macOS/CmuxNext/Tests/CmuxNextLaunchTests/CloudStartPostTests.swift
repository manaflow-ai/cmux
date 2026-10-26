import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The launch's Cloud start (p08-startup task 020): never before the first frame; right after it when a
/// window shows a remote machine's workspace, else once startup completes.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CloudStartPostTests {
    @Test func aShownRemoteWorkspaceStartsCloudRightAfterTheFirstFrame() {
        let s = StartupTestScheduler(), starts = StartCount()
        CloudStartPost(showsRemoteWorkspace: { true }, start: { starts.count += 1 }).post(on: s.startup)
        s.fire()
        #expect(starts.count == 0, "nothing starts before the first frame")
        s.startup.firstFrameCommitted()
        s.fire()
        #expect(starts.count == 1, "the remote workspace's machine connects after the first frame")
        #expect(s.startup.completion == nil, "it did not wait for startup to complete")
        s.startup.finishRegistration()
        s.hand.drain()
        for _ in 0..<3 { s.fire() }
        #expect(starts.count == 1, "started once")
    }

    @Test func withNoRemoteWorkspaceCloudStartsAfterStartup() {
        let s = StartupTestScheduler(), starts = StartCount()
        CloudStartPost(showsRemoteWorkspace: { false }, start: { starts.count += 1 }).post(on: s.startup)
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

    @Test func quitBeforeTheFirstFrameNeverStartsCloud() {
        let s = StartupTestScheduler(), starts = StartCount()
        CloudStartPost(showsRemoteWorkspace: { true }, start: { starts.count += 1 }).post(on: s.startup)
        s.startup.beginQuit()
        s.startup.firstFrameCommitted()
        for _ in 0..<3 { s.fire() }
        #expect(starts.count == 0)
    }
}

@MainActor
private final class StartCount {
    var count = 0
}
