import AppKit
@testable import CmuxNextRemoteView
import Foundation
import Testing

/// conn-quiet (Leo, 2026-11-14: connectivity should "shut the f*** up and load faster"): a
/// Cloud desktop that reconnects over its last frame says nothing until it has tried for
/// ``RemotePaneState/reconnectNoticeDelay``, and a path that closed under a live picture comes
/// back by itself instead of showing "Connection lost" with a Reconnect button.
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

    @Test func aFirstConnectStillSaysConnecting() {
        let state = RemotePaneState(hostName: "vm", requestedMode: .view)
        #expect(state.overlay == .connecting)
    }

    /// The path closes under a live picture: the pane reconnects at once, silently.
    @Test func aLostPathReconnectsByItself() async {
        let source = MockRemoteStreamSource(status: RemoteViewStatus(state: .streaming))
        let pane = RemoteDesktopPane(hostName: "vm", source: source, inputSink: nil, initialMode: .view, viaCloudTunnel: true,
                                     modeControl: .takeOver)
        pane.autoReconnectsLost = true
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
        pane.autoReconnectsLost = true
        var reconnects = 0
        pane.handlers.reconnect = { reconnects += 1 }
        pane.apply(.status(RemoteViewStatus(state: .streaming)))
        pane.apply(.frameShown)
        pane.apply(.stop)
        pane.apply(.status(RemoteViewStatus(state: .ended(.connectionLost))))
        #expect(pane.state.isEnded)
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(reconnects == 0)
    }

    /// A first connect that never showed a frame keeps its card and Reconnect button.
    @Test func aLostPathWithNoPictureYetKeepsTheEndedCard() {
        let source = MockRemoteStreamSource(status: RemoteViewStatus(state: .connecting))
        let pane = RemoteDesktopPane(hostName: "vm", source: source, inputSink: nil, initialMode: .view, viaCloudTunnel: true,
                                     modeControl: .takeOver)
        pane.autoReconnectsLost = true
        pane.apply(.status(RemoteViewStatus(state: .ended(.connectionLost))))
        #expect(pane.state.overlay == .ended(.connectionLost))
    }
}
