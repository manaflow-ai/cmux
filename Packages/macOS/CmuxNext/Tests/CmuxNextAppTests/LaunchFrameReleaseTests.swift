@testable import CmuxNextApp
import Observation
import Testing

/// #17587 review: the decoded launch frames no pane took (fully decoded bitmaps, about 5 MB per
/// Retina pane) are dropped at one launch end that always comes. Before, they were dropped only once
/// every restored window without content installed it: a launch window with no workspace to show
/// (the daemon failed to create one; it keeps the startup state) never does, and the daemon's
/// unavailable startup was no longer watched after the restore, so the frames stayed for the session.
@MainActor @Suite(.timeLimit(.minutes(1))) struct LaunchFrameReleaseTests {
    @MainActor @Observable final class Daemon {
        var isUnavailable = false
    }

    typealias Window = LaunchFrameRelease.Window

    @Test func theFramesGoOnceEveryWindowShowedItsContent() {
        var released = 0
        let release = LaunchFrameRelease(daemonUnavailable: { false }) { released += 1 }
        release.restoreEnded([Window(id: "w1", showsContent: false, isLocal: true, hasWorkspaceToShow: true),
                              Window(id: "w2", showsContent: true, isLocal: true, hasWorkspaceToShow: true),
                              Window(id: "remote", showsContent: false, isLocal: false, hasWorkspaceToShow: true)])
        #expect(released == 0, "w1 has not shown its panes yet")
        release.windowDone("w1")
        #expect(released == 1)
        release.windowDone("w1")
        #expect(released == 1, "released once")
    }

    @Test func aWindowWithNoWorkspaceToShowDoesNotHoldTheFrames() {
        var released = 0
        let release = LaunchFrameRelease(daemonUnavailable: { false }) { released += 1 }
        // The launch window, whose workspace the daemon failed to create, keeps the startup state.
        release.restoreEnded([Window(id: "launch", showsContent: false, isLocal: true, hasWorkspaceToShow: false),
                              Window(id: "w1", showsContent: false, isLocal: true, hasWorkspaceToShow: true)])
        release.windowDone("w1")
        #expect(released == 1, "a window that will never install content kept every decoded frame for the session")
    }

    @Test func aDaemonUnavailableAfterTheRestoreReleasesTheFrames() async {
        let daemon = Daemon()
        let (released, didRelease) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = LaunchFrameRelease(daemonUnavailable: { daemon.isUnavailable }) { didRelease.yield() }
        release.restoreEnded([Window(id: "w1", showsContent: false, isLocal: true, hasWorkspaceToShow: true)])
        // Let the watch take its first look before the change.
        await Task.yield()
        daemon.isUnavailable = true
        for await _ in released { break }
        #expect(release.isReleased, "a window waiting on a daemon that went away kept the frames for the session")
    }

    @Test func aDaemonUnavailableBeforeTheRestoreReleasesTheFrames() async {
        let daemon = Daemon()
        let (released, didRelease) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = LaunchFrameRelease(daemonUnavailable: { daemon.isUnavailable }) { didRelease.yield() }
        await Task.yield()
        daemon.isUnavailable = true
        for await _ in released { break }
        #expect(release.isReleased)
    }
}
