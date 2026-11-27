import AppKit
@testable import CmuxNextRemoteView
import Foundation
import Testing

// The API under test is DEBUG-only, so `swift test -c release` skips this file.
#if DEBUG

/// conn-quiet (Leo, 2026-11-14: connectivity should "shut the f*** up and load faster"): a
/// Cloud desktop that reconnects over its last frame says nothing until it has tried for
/// ``RemotePaneState/reconnectNoticeDelay``, and a path that closed under a live picture comes
/// back by itself instead of showing "Connection lost" with a Reconnect button. Leo, 2026-11-22: a
/// Reconnect press is a vacuous decision ("vacuous decisions like that should be just done"), so the
/// pane keeps trying for as long as it shows, and no lost path ever asks for one.
@MainActor
@Suite struct RemotePaneQuietReconnectTests {
    private func streamingWithFrame() -> RemotePaneState {
        var state = RemotePaneState(hostName: "vm", requestedMode: .view)
        let reducer = RemotePaneReducer()
        state = reducer.reduce(state, .status(RemoteViewStatus(state: .streaming)))
        return reducer.reduce(state, .frameShown)
    }

    /// Take over, Hand back and Reconnect restart the session: no card over the last frame.
    @Test func aRestartOverTheLastFrameShowsNoCard() {
        let restarted = RemotePaneReducer().reduce(streamingWithFrame(), .restartForMode)
        #expect(restarted.sessionState == .connecting)
        #expect(restarted.overlay == nil)
        let streamingAgain = RemotePaneReducer().reduce(restarted, .status(RemoteViewStatus(state: .streaming)))
        #expect(streamingAgain.overlay == nil, "streaming, before the new session's first frame")
    }

    @Test func theCardShowsOnlyOnceTheReconnectRanForTheBound() {
        let start = ContinuousClock.now
        let reducer = RemotePaneReducer()
        let restarted = reducer.reduce(streamingWithFrame(), .restartForMode, now: start)
        #expect(restarted.reconnectingSince == start)
        let early = reducer.reduce(restarted, .reconnectNoticeCheck, now: start + .seconds(9))
        #expect(early.overlay == nil)
        let due = reducer.reduce(restarted, .reconnectNoticeCheck, now: start + RemotePaneState.reconnectNoticeDelay)
        #expect(due.overlay == .connecting)
        let back = reducer.reduce(reducer.reduce(due, .status(RemoteViewStatus(state: .streaming))), .frameShown)
        #expect(back.overlay == nil)
        #expect(back.reconnectingSince == nil)
        #expect(!back.reconnectNoticeDue)
    }

    /// A state no reducer stamped (a gallery's or a test's) still draws the connecting card.
    @Test func aFirstConnectStillSaysConnecting() {
        let state = RemotePaneState(hostName: "vm", requestedMode: .view)
        #expect(state.overlay == .connecting)
    }

    /// The pane stamps its first connect at its start: no card for the coming-up time, then the card with Cancel.
    @Test func aNewPaneHoldsItsConnectingCardForTheComingUpTime() throws {
        let source = MockRemoteStreamSource(status: RemoteViewStatus(state: .connecting))
        let pane = RemoteDesktopPane(hostName: "vm", source: source, inputSink: nil, initialMode: .view)
        let since = try #require(pane.state.connectingSince)
        #expect(pane.state.overlay == nil)
        #expect(pane.view.connectingCard == nil)
        let due = RemotePaneReducer().reduce(pane.state, .connectNoticeCheck, now: since + RemotePaneState.connectNoticeDelay)
        #expect(due.overlay == .connecting)
        #expect(due.connectingSince == since)
    }

    /// The path closes under a live picture: the pane reconnects at once, silently.
    @Test func aLostPathReconnectsByItself() async {
        let source = MockRemoteStreamSource(status: RemoteViewStatus(state: .streaming))
        let pane = RemoteDesktopPane(hostName: "vm", source: source, inputSink: nil, initialMode: .view, viaCloudTunnel: true,
                                     modeControl: .takeOver)
        var reconnects = 0
        pane.handlers.reconnect = { reconnects += 1 }
        pane.apply(.status(RemoteViewStatus(state: .streaming)))
        pane.apply(.frameShown)
        pane.apply(.status(RemoteViewStatus(state: .ended(.connectionLost))))
        #expect(pane.state.sessionState == .connecting)
        #expect(pane.state.overlay == nil, "no Connection lost card")
        for _ in 0 ..< 50 where reconnects == 0 { await Task.yield() }
        #expect(reconnects == 1, "the first try goes at once")
    }

    /// Stop, then the transport's own lost-path status arrives late: the pane stays stopped.
    @Test func aLostPathAfterStopDoesNotReconnect() async {
        let source = MockRemoteStreamSource(status: RemoteViewStatus(state: .streaming))
        let pane = RemoteDesktopPane(hostName: "vm", source: source, inputSink: nil, initialMode: .view, viaCloudTunnel: true,
                                     modeControl: .takeOver)
        var reconnects = 0
        pane.handlers.reconnect = { reconnects += 1 }
        pane.apply(.status(RemoteViewStatus(state: .streaming)))
        pane.apply(.frameShown)
        pane.apply(.stop)
        pane.apply(.status(RemoteViewStatus(state: .ended(.connectionLost))))
        #expect(pane.state.sessionState == .ended(.stoppedByViewer), "the card still says Stopped, with its Reconnect")
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(reconnects == 0)
    }

    /// A first connect that never showed a frame tries again too, still saying "Connecting".
    @Test func aLostPathWithNoPictureYetConnectsAgain() async {
        let source = MockRemoteStreamSource(status: RemoteViewStatus(state: .connecting))
        let pane = RemoteDesktopPane(hostName: "vm", source: source, inputSink: nil, initialMode: .view, viaCloudTunnel: true,
                                     modeControl: .takeOver)
        var reconnects = 0
        pane.handlers.reconnect = { reconnects += 1 }
        pane.apply(.status(RemoteViewStatus(state: .ended(.connectionLost))))
        #expect(pane.state.overlay == .connecting)
        for _ in 0 ..< 50 where reconnects == 0 { await Task.yield() }
        #expect(reconnects == 1)
    }

    /// No last try: past the backoff's end the pane keeps trying at its last step, and never
    /// shows the "Connection lost" card.
    @Test func theTriesNeverRunOut() {
        let source = MockRemoteStreamSource(status: RemoteViewStatus(state: .streaming))
        let pane = RemoteDesktopPane(hostName: "vm", source: source, inputSink: nil, initialMode: .view, viaCloudTunnel: true,
                                     modeControl: .takeOver)
        pane.apply(.status(RemoteViewStatus(state: .streaming)))
        pane.apply(.frameShown)
        for _ in 0 ... RemoteDesktopPane.autoReconnectBackoff.count + 2 {
            pane.apply(.status(RemoteViewStatus(state: .ended(.connectionLost))))
            #expect(pane.state.sessionState == .connecting)
            #expect(pane.state.overlay == nil || pane.state.overlay == .connecting)
            pane.apply(.status(RemoteViewStatus(state: .connecting)))
        }
        #expect(pane.autoReconnects == RemoteDesktopPane.autoReconnectBackoff.count + 3)
        pane.stop()
    }

    /// A hide that cut a backoff wait short: showing the pane again (a Cloud desktop's session
    /// lived through the hide) sends that reconnect instead of leaving "Reconnecting…" stuck.
    @Test func aHideDuringTheBackoffResumesTheReconnect() async {
        let source = MockRemoteStreamSource(status: RemoteViewStatus(state: .streaming))
        let pane = RemoteDesktopPane(hostName: "vm", source: source, inputSink: nil, initialMode: .view, viaCloudTunnel: true,
                                     modeControl: .takeOver)
        var reconnects = 0
        pane.handlers.reconnect = { reconnects += 1 }
        pane.apply(.status(RemoteViewStatus(state: .streaming)))
        pane.apply(.frameShown)
        pane.apply(.status(RemoteViewStatus(state: .ended(.connectionLost))))
        for _ in 0 ..< 50 where reconnects == 0 { await Task.yield() }
        #expect(reconnects == 1)
        // The first try's dial lost the path too: the second waits 1 s, and the hide cuts it short.
        pane.apply(.status(RemoteViewStatus(state: .connecting)))
        pane.apply(.status(RemoteViewStatus(state: .ended(.connectionLost))))
        pane.stop()
        pane.resumeInterruptedReconnect()
        pane.resumeInterruptedReconnect()
        #expect(pane.autoReconnects == 2, "the resumed wait is the same step, once")
        pane.stop()
    }
}
#endif
