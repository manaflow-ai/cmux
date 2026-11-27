@testable import CmuxNextRemoteView
import Foundation
import Testing

/// One RTT sample over the interactive limit flipped the pane to view only with "View only: high
/// latency", and the next sample under it took that back. The pane now holds the state: the path
/// must stay over the limit for `RemoteLatencyHold.sustain` to count as high, and under it as long
/// to count as low again (error-states audit, 2026-11-12).
@Suite struct RemoteLatencyHoldTests {
    private let reducer = RemotePaneReducer()
    private let start = ContinuousClock.now

    private func streaming(_ state: RemotePaneState, rtt: Int, at seconds: Double) -> RemotePaneState {
        reducer.reduce(state, .status(RemoteViewStatus(rttMs: rtt, state: .streaming)), now: start + .seconds(seconds))
    }

    @Test func oneSlowSampleShowsNothing() {
        var state = RemotePaneState(hostName: "box", requestedMode: .control, interactiveMaxRttMs: 80)
        state = streaming(state, rtt: 20, at: 0)
        state = streaming(state, rtt: 400, at: 1)
        #expect(!state.showsLatencyBanner)
        #expect(state.effectiveMode == .control)
        state = streaming(state, rtt: 20, at: 2)
        state = streaming(state, rtt: 400, at: 3.5)
        #expect(!state.showsLatencyBanner, "a dip under the limit starts the hold again")
    }

    @Test func aSustainedSlowPathShowsAndASustainedFastOneHides() {
        var state = RemotePaneState(hostName: "box", requestedMode: .control, interactiveMaxRttMs: 80)
        state = streaming(state, rtt: 400, at: 0)
        state = streaming(state, rtt: 400, at: 2.9)
        #expect(!state.showsLatencyBanner)
        state = streaming(state, rtt: 400, at: 3)
        #expect(state.showsLatencyBanner)
        #expect(state.effectiveMode == .view)
        // One fast sample does not take it back; three seconds of them do.
        state = streaming(state, rtt: 20, at: 4)
        #expect(state.showsLatencyBanner)
        state = streaming(state, rtt: 20, at: 6.9)
        #expect(state.showsLatencyBanner)
        state = streaming(state, rtt: 20, at: 7)
        #expect(!state.showsLatencyBanner)
        #expect(state.effectiveMode == .control)
    }

    @Test func aDueCheckFlipsWithNoNewSample() {
        var state = RemotePaneState(hostName: "box", requestedMode: .control, interactiveMaxRttMs: 80)
        state = streaming(state, rtt: 400, at: 0)
        #expect(state.latency.due == start + RemoteLatencyHold.sustain)
        state = reducer.reduce(state, .latencyCheck, now: start + RemoteLatencyHold.sustain)
        #expect(state.showsLatencyBanner)
        #expect(state.latency.due == nil)
        // A new session has no measured path: nothing is held.
        state = reducer.reduce(reducer.reduce(state, .stop, now: start + .seconds(4)), .reconnect, now: start + .seconds(5))
        #expect(!state.isHighLatency)
    }
}
