import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import CmuxScreenKit
import Foundation
import Testing

/// A connected viewer holds one capture vote on the app's node, so the windows
/// the shared screen may show render while hidden and their pages still read hidden; every way the
/// session ends releases it.
@MainActor
struct MacScreenHubShareVoteTests {
    /// The stream hosts the hub host made, so a test can send their events.
    final class MadeHosts {
        var items: [ScreenStreamHost] = []
    }

    /// A host serving session `s1` whose shared screen is a hidden app node with one window under it.
    private func serving() -> (host: MacScreenHubHost, app: VisibilityNode, window: VisibilityNode, made: MadeHosts) {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file, runner: BackgroundWork(label: "test.mac-screen")), deadlines: linklessDeadlines(), appEvents: AppEvents(center: NotificationCenter()), work: BackgroundWork())
        let hub = testHub()
        let host = pages.hubHost
        let app = VisibilityNode(root: "app", own: .hidden)
        let window = VisibilityNode("window", own: .visible, parent: app)
        host.sharedScreenNode = app
        host.hub = { hub }
        host.makeSignaling = { _, _ in MacScreenHubHostOrderTests.OpenSignaling() }
        let made = MadeHosts()
        let make = host.makeHost
        host.makeHost = { name, viewOnly in
            let stream = make(name, viewOnly)
            made.items.append(stream)
            return stream
        }
        host.endSession = { _, _, _ in }
        host.serve(ticket("s1", role: .host, scope: .full, peer: "v1"))
        return (host, app, window, made)
    }

    /// Sends `.viewerConnected` from the session's stream host and waits until the hub host handled it.
    private func connect(_ host: MacScreenHubHost, _ made: MadeHosts) throws {
        let stream = try #require(made.items.last)
        stream.onEvent?(.viewerConnected)
        // The event reaches main as one posted visible task.
        try #require(runMainLoop { host.session?.connected == true }, "the viewer's connection was not handled")
    }

    private func expectCapturedHidden(_ app: VisibilityNode, _ window: VisibilityNode) {
        #expect(app.isCaptured && window.isCaptured && window.wantsFrames, "a connected viewer took no vote")
        #expect(app.effective == .hidden && window.effective == .hidden, "the vote showed the windows' pages")
        #expect(app.captureReasons == ["mac-screen.share"])
    }

    private func expectReleased(_ app: VisibilityNode, _ window: VisibilityNode) {
        #expect(!app.isCaptured && !window.isCaptured && !window.wantsFrames, "the ended session kept its vote")
        #expect(app.captureReasons.isEmpty)
    }

    @Test func aServedSessionVotesOnlyOnceAViewerConnects() async throws {
        let (host, app, window, made) = serving()
        #expect(!app.isCaptured, "a session nobody watches took a vote")
        try connect(host, made)
        expectCapturedHidden(app, window)
        // A repeated connection notice keeps the one vote.
        made.items.last?.onEvent?(.viewerConnected)
        let deadline = Date(timeIntervalSinceNow: 0.2)
        _ = runMainLoop { Date() >= deadline }
        #expect(app.captureReasons == ["mac-screen.share"])
        host.closeAll()
        expectReleased(app, window)
    }

    @Test func theViewerLeavingReleasesTheVote() async throws {
        let (host, app, window, made) = serving()
        try connect(host, made)
        expectCapturedHidden(app, window)
        try #require(made.items.last).onEvent?(.viewerEnded)
        #expect(runMainLoop { host.session == nil })
        expectReleased(app, window)
    }

    @Test func stopSharingReleasesTheVote() async throws {
        let (host, app, window, made) = serving()
        try connect(host, made)
        expectCapturedHidden(app, window)
        await host.stopSession()?.value
        #expect(host.session == nil)
        expectReleased(app, window)
    }

    @Test func theHubEndingTheSessionReleasesTheVote() async throws {
        let (host, app, window, made) = serving()
        try connect(host, made)
        expectCapturedHidden(app, window)
        host.sessionOver("s1")
        expectReleased(app, window)
    }
}
