@testable import CmuxNextRemoteView
import Foundation
import Testing

/// The before/after harness for the remote desktop's connection labels (Leo, 2026-11-14: "i also want all our
/// connectivity stuff to shut up and load faster"): it plays one connect or reconnect through the pane's reducer on
/// a made-up clock, samples what the pane would draw every 10 ms (each sample is the deadline check the pane's timer
/// sends), and adds up how long a card stood over the pane. It uses only events the reducer had before the
/// coming-up hold, so the same file measures the base and this change.
@Suite struct RemoteConnectLabelExposureTests {
    private static let step = 10

    /// A connect or reconnect: the events, each at its offset in ms, and how long to watch.
    private struct Script {
        var name: String
        var start: RemotePaneState
        var events: [(ms: Int, event: RemotePaneEvent)]
        var until: Int
    }

    /// The ms a card (Connecting, Reconnecting or any other) stood over the pane, and the first ms the pane drew no
    /// card with a frame on screen (time to interactive; nil if it never did).
    private static func play(_ script: Script) -> (cardMs: Int, interactiveAt: Int?) {
        let reducer = RemotePaneReducer()
        let zero = ContinuousClock.now
        var state = script.start
        var pending = script.events
        var cardMs = 0
        var interactiveAt: Int?
        var ms = 0
        while ms <= script.until {
            while let first = pending.first, first.ms <= ms {
                state = reducer.reduce(state, first.event, now: zero + .milliseconds(first.ms))
                pending.removeFirst()
            }
            state = reducer.reduce(state, .reconnectNoticeCheck, now: zero + .milliseconds(ms))
            if state.overlay != nil { cardMs += step }
            if interactiveAt == nil, state.hasFrame, state.overlay == nil { interactiveAt = ms }
            ms += step
        }
        return (cardMs, interactiveAt)
    }

    private static func streamingWithFrame() -> RemotePaneState {
        let reducer = RemotePaneReducer()
        let state = reducer.reduce(RemotePaneState(hostName: "vm", requestedMode: .view), .status(RemoteViewStatus(state: .streaming)))
        return reducer.reduce(state, .frameShown)
    }

    private static func firstConnect(_ name: String, streamAt: Int, frameAt: Int) -> Script {
        Script(name: name, start: RemotePaneState(hostName: "vm", requestedMode: .view), events: [
            (0, .status(RemoteViewStatus(state: .connecting))),
            (streamAt, .status(RemoteViewStatus(state: .streaming))),
            (frameAt, .frameShown),
        ], until: frameAt + 500)
    }

    private static func reconnect(_ name: String, after: Int) -> Script {
        Script(name: name, start: streamingWithFrame(), events: [
            (0, .restartForMode),
            (after - 100, .status(RemoteViewStatus(state: .streaming))),
            (after, .frameShown),
        ], until: after + 500)
    }

    private static func measure(_ script: Script) -> (cardMs: Int, interactiveAt: Int?) {
        let result = play(script)
        print("remote-label-exposure \(script.name): card_ms=\(result.cardMs) interactive_at_ms=\(result.interactiveAt.map(String.init) ?? "never")")
        return result
    }

    @Test func aConnectUnderOneSecondDrawsNoCard() {
        #expect(Self.measure(Self.firstConnect("connect-600ms", streamAt: 400, frameAt: 600)).cardMs == 0)
        #expect(Self.measure(Self.firstConnect("connect-950ms", streamAt: 700, frameAt: 950)).cardMs == 0)
    }

    @Test func aSlowConnectShowsItsCardAfterOneSecond() {
        let slow = Self.measure(Self.firstConnect("connect-2500ms", streamAt: 2000, frameAt: 2500))
        #expect(slow.cardMs == 1500, "the card after the 1 s coming-up time, until the first frame at 2.5 s")
    }

    @Test func aReconnectUnderTenSecondsDrawsNoCard() {
        #expect(Self.measure(Self.reconnect("reconnect-4s", after: 4000)).cardMs == 0)
        #expect(Self.measure(Self.reconnect("reconnect-9.5s", after: 9500)).cardMs == 0)
    }

    @Test func aLongReconnectShowsItsCardAtTenSeconds() {
        #expect(Self.measure(Self.reconnect("reconnect-12s", after: 12000)).cardMs == 2000)
    }

    /// Waiting on the other side's approval needs a person: it shows at once, as before.
    @Test func consentShowsAtOnce() {
        let script = Script(name: "consent", start: RemotePaneState(hostName: "vm", requestedMode: .view), events: [
            (0, .status(RemoteViewStatus(state: .connecting))),
            (300, .status(RemoteViewStatus(state: .waitingForConsent))),
        ], until: 1300)
        #expect(Self.measure(script).cardMs == 1010)
    }

    /// A failure with its Reconnect button shows at once, even inside the coming-up time.
    @Test func aFailureShowsAtOnce() {
        let script = Script(name: "fail-200ms", start: RemotePaneState(hostName: "vm", requestedMode: .view), events: [
            (0, .status(RemoteViewStatus(state: .connecting))),
            (200, .status(RemoteViewStatus(state: .ended(.connectionLost)))),
        ], until: 700)
        #expect(Self.measure(script).cardMs == 510)
    }
}
