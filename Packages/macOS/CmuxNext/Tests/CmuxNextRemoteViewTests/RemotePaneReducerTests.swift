import Testing
@testable import CmuxNextRemoteView

struct RemotePaneReducerTests {
    private func reduce(_ state: RemotePaneState, _ events: RemotePaneEvent...) -> RemotePaneState {
        events.reduce(state, RemotePaneReducer().reduce)
    }

    private func streaming(rtt: Int, path: RemotePath = .direct) -> RemotePaneEvent {
        .status(RemoteViewStatus(path: path, rttMs: rtt, state: .streaming))
    }

    @Test func connectsThenStreamsOnTheFirstFrame() {
        var state = RemotePaneState(hostName: "build-linux")
        #expect(state.overlay == .connecting)
        #expect(state.pinsToolbar)
        #expect(!state.showsSessionControls)
        state = reduce(state, streaming(rtt: 4))
        // Streaming but nothing decoded yet: still the connecting card.
        #expect(state.overlay == .connecting)
        state = reduce(state, .frameShown)
        #expect(state.overlay == nil)
        #expect(state.effectiveMode == .control)
        #expect(state.showsSessionControls)
        #expect(!state.pinsToolbar)
    }

    @Test func consentWaitShowsTheCard() {
        let state = reduce(RemotePaneState(hostName: "mac"), .status(RemoteViewStatus(state: .waitingForConsent)))
        #expect(state.overlay == .waitingForConsent)
        #expect(state.effectiveMode == .view)
    }

    @Test func highLatencyIsViewOnlyUntilControlAnyway() {
        var state = reduce(RemotePaneState(hostName: "vm", interactiveMaxRttMs: 80), streaming(rtt: 120, path: .relayed), .frameShown)
        #expect(state.isHighLatency)
        #expect(state.effectiveMode == .view)
        #expect(state.showsLatencyBanner)
        state = reduce(state, .controlAnyway)
        #expect(state.effectiveMode == .control)
        #expect(!state.showsLatencyBanner)
        // The choice survives RTT changes within the session.
        state = reduce(state, streaming(rtt: 200, path: .relayed))
        #expect(state.effectiveMode == .control)
    }

    @Test func latencyAtTheLimitStaysInteractive() {
        let state = reduce(RemotePaneState(hostName: "vm", interactiveMaxRttMs: 80), streaming(rtt: 80), .frameShown)
        #expect(!state.isHighLatency)
        #expect(state.effectiveMode == .control)
        let raised = reduce(state, streaming(rtt: 81))
        #expect(raised.effectiveMode == .view)
        let relaxed = reduce(raised, .setInteractiveMaxRtt(100))
        #expect(relaxed.effectiveMode == .control)
    }

    @Test func viewModeHidesTheBannerAndClearsTheOverride() {
        var state = reduce(RemotePaneState(hostName: "vm"), streaming(rtt: 150), .frameShown, .controlAnyway)
        state = reduce(state, .selectMode(.view))
        #expect(state.effectiveMode == .view)
        #expect(!state.showsLatencyBanner)
        state = reduce(state, .selectMode(.control))
        #expect(state.effectiveMode == .view)
        #expect(state.showsLatencyBanner)
    }

    @Test func controlAnywayNeedsAHighLatencyStream() {
        let state = reduce(RemotePaneState(hostName: "vm"), streaming(rtt: 5), .frameShown, .controlAnyway)
        #expect(!state.controlDespiteLatency)
    }

    @Test func endedStatesKeepTheLastFrameAndOfferReconnect() {
        let live = reduce(RemotePaneState(hostName: "mac"), streaming(rtt: 3), .frameShown)
        let kicked = reduce(live, .status(RemoteViewStatus(state: .ended(.disconnectedBy(name: "Ana")))))
        #expect(kicked.overlay == .ended(.disconnectedBy(name: "Ana")))
        #expect(kicked.hasFrame)
        #expect(kicked.effectiveMode == .view)
        #expect(!kicked.showsSessionControls)
        let stopped = reduce(live, .status(RemoteViewStatus(state: .ended(.hostStoppedSharing))))
        #expect(stopped.overlay == .ended(.hostStoppedSharing))
        let reconnecting = reduce(stopped, .reconnect)
        #expect(reconnecting.overlay == .connecting)
        #expect(!reconnecting.hasFrame)
        #expect(reconnecting.status?.rttMs == nil)
    }

    @Test func stopEndsOnceAndReconnectNeedsAnEnd() {
        let live = reduce(RemotePaneState(hostName: "mac"), streaming(rtt: 3), .frameShown)
        let stopped = reduce(live, .stop)
        #expect(stopped.overlay == .ended(.stoppedByViewer))
        #expect(reduce(stopped, .stop) == stopped)
        #expect(reduce(live, .reconnect) == live)
    }

    @Test func frameBeforeStreamingDoesNotCount() {
        let state = reduce(RemotePaneState(hostName: "mac"), .frameShown)
        #expect(!state.hasFrame)
    }

    @Test func newSessionAfterAnEndResetsTheOverride() {
        var state = reduce(RemotePaneState(hostName: "vm"), streaming(rtt: 150), .frameShown, .controlAnyway)
        state = reduce(state, .status(RemoteViewStatus(state: .ended(.connectionLost))))
        state = reduce(state, .status(RemoteViewStatus(state: .connecting)))
        #expect(!state.controlDespiteLatency)
        #expect(!state.hasFrame)
    }
}
