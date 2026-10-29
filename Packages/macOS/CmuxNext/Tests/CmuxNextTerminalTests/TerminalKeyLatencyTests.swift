import CmuxNextInput
import CmuxNextInputCore
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// The terminals' latency sink: a key's echo stages and the daemon's stamps reach the tracker's
/// slot; a key that ends with no frame stamps nothing, so its slot closes at the tracker's content deadline.
@MainActor
struct TerminalKeyLatencyTests {
    private func tracker() -> InputLatencyTracker {
        InputLatencyTracker(presentation: PresentationClock(), frameIntervals: nil)
    }

    @Test func echoStagesAndDaemonStampsReachTheKeySlot() throws {
        let tracker = tracker()
        let sink = TerminalKeyLatency(tracker: tracker)
        let token = try #require(tracker.begin(kind: .keyPress, target: .terminal, entrypoint: .person,
                                               eventTimestamp: 0, window: nil))
        #expect(sink.dispatchingKey == token)
        let start = try #require(tracker.table.time(token, .dispatchStart))
        tracker.endDispatch(token)
        #expect(sink.dispatchingKey == nil)

        sink.keyEchoStamped(flow: token.keyFlow, TerminalKeyStamps(received: start + 10, written: start + 20,
                                                                   read: start + 30, sent: start + 40),
                            decodedAt: start + 50)
        sink.terminalEcho(token, .echoParsed, at: start + 60)
        sink.terminalEcho(token, .contentSubmitted, at: start + 70)
        #expect(tracker.table.time(token, .daemonReceived) == start + 10)
        #expect(tracker.table.time(token, .echoSent) == start + 40)
        #expect(tracker.table.time(token, .echoParsed) == start + 60)
        #expect(tracker.table.time(token, .contentSubmitted) == start + 70)
    }

    @Test func aKeyWithNoFrameStampsNothing() throws {
        let tracker = tracker()
        let sink = TerminalKeyLatency(tracker: tracker)
        let token = try #require(tracker.begin(kind: .keyPress, target: .terminal, entrypoint: .person,
                                               eventTimestamp: 0, window: nil))
        let start = try #require(tracker.table.time(token, .dispatchStart))
        for event: TerminalEchoEvent in [.noEcho, .noFrame, .superseded, .surfaceClosed] {
            sink.terminalEcho(token, event, at: start + 10)
        }
        for stage: InputStage in [.echoParsed, .contentSubmitted, .presented] {
            #expect(tracker.table.time(token, stage) == nil, "\(stage)")
        }
    }
}
