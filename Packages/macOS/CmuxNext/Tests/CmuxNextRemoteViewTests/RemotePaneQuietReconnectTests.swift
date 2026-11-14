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

    @Test func aFirstConnectStillSaysConnecting() {
        let state = RemotePaneState(hostName: "vm", requestedMode: .view)
        #expect(state.overlay == .connecting)
    }
}
