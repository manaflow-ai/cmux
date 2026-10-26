import CoreGraphics
@testable import CmuxNextRemoteView
@testable import CmuxNextTrace
import Testing

/// Task p09-observability-127: the remote desktop view's `remote.input`, `remote.frame_decoded` and
/// `remote.present` trace points, and the arithmetic of `remote.input_to_present` and
/// `smoothness.dropped_pct.remote_stream`.
@Suite(.timeLimit(.minutes(1)))
struct RemoteStreamLatencyTests {
    /// A runtime with every category on, so each trace point that runs adds one record.
    private func recordingRuntime() -> TraceRuntime {
        let runtime = TraceRuntime(role: .app)
        runtime.setCategoryMask(.max)
        return runtime
    }

    private func records(_ runtime: TraceRuntime) -> UInt64 {
        runtime.stubRecordCount.load(ordering: .relaxed)
    }

    /// A clock that always reads `micros` microseconds.
    private func fixedClock(micros: UInt64) -> TraceClock {
        TraceClock(reader: .init(uptimeNanos: { micros * 1_000 }, continuousNow: { ContinuousClock.now }))
    }

    // MARK: input numbering and send times

    @Test func sequencerStartsAtOneAndNeverYieldsZero() {
        var sequencer = RemoteInputLatency.Sequencer()
        #expect(sequencer.next() == 1)
        #expect(sequencer.next() == 2)
    }

    @Test func sendTimesAreKeptUntilALaterInputTakesTheirSlot() {
        let latency = RemoteInputLatency(runtime: recordingRuntime(), clock: fixedClock(micros: 7_000))
        latency.recordSent(5)
        #expect(latency.sentMicros(5) == 7_000)
        #expect(latency.sentMicros(6) == nil)
        latency.recordSent(5 + UInt32(RemoteInputLatency.capacity))
        #expect(latency.sentMicros(5) == nil)
        #expect(latency.sentMicros(0) == nil)
    }

    @Test func remoteInputPointWritesOnlyUnderTheRemoteCategory() {
        let runtime = TraceRuntime(role: .app)
        let latency = RemoteInputLatency(runtime: runtime, clock: fixedClock(micros: 1))
        latency.recordSent(1)
        #expect(records(runtime) == 0)
        runtime.setCategoryMask(.max)
        latency.recordSent(2)
        latency.recordSent(0)
        #expect(records(runtime) == 1)
    }

    @MainActor @Test func inputControllerNumbersEverySentEvent() {
        final class Recorder: RemoteViewInputSink {
            var events: [RemoteInputEvent] = []
            func send(_ event: RemoteInputEvent) { events.append(event) }
        }
        let runtime = recordingRuntime()
        let controller = RemoteInputController(inputLatency: RemoteInputLatency(runtime: runtime, clock: fixedClock(micros: 9)))
        let sink = Recorder()
        controller.sink = sink
        controller.isActive = true
        controller.pointer((x: 3, y: 4))
        controller.button(.left, down: true, at: (x: 3, y: 4))
        #expect(sink.events.count == 3)
        #expect(records(runtime) == 3)
        #expect(controller.inputLatency.sentMicros(3) == 9)
        #expect(controller.inputLatency.sentMicros(4) == nil)
    }

    // MARK: dropped frames

    @Test func everyFrameShownReportsZeroDroppedOnceAWindowFills() {
        var ledger = RemoteStreamPresentLedger()
        let window = RemoteStreamPresentLedger.windowFrames
        for frame in 0..<window - 1 { #expect(ledger.frameCompleted(frame, shown: true) == nil) }
        #expect(ledger.frameCompleted(window - 1, shown: true) == 0)
    }

    @Test func framesMissingOrNotShownCountAsDropped() {
        var ledger = RemoteStreamPresentLedger()
        var reports: [Int64] = []
        // Frames 10-14 never reach the presenter (lost, skipped or replaced); frames 20-22 are drawn but never shown.
        for frame in UInt32(0)..<RemoteStreamPresentLedger.windowFrames where !(10..<15).contains(frame) {
            if let percent = ledger.frameCompleted(frame, shown: !(20..<23).contains(frame)) { reports.append(percent) }
        }
        #expect(reports == [8])
    }

    @Test func aLateFrameOfAReportedWindowIsIgnored() {
        var ledger = RemoteStreamPresentLedger()
        for frame in UInt32(0)..<RemoteStreamPresentLedger.windowFrames { _ = ledger.frameCompleted(frame, shown: true) }
        #expect(ledger.frameCompleted(50, shown: true) == nil)
        var reports: [Int64] = []
        for frame in RemoteStreamPresentLedger.windowFrames..<2 * RemoteStreamPresentLedger.windowFrames {
            if let percent = ledger.frameCompleted(frame, shown: true) { reports.append(percent) }
        }
        #expect(reports == [0])
    }

    @Test func aJumpOrRestartStartsANewSequenceInsteadOfCountingDrops() {
        var ledger = RemoteStreamPresentLedger()
        let window = RemoteStreamPresentLedger.windowFrames
        for frame in UInt32(1_000)..<1_050 { _ = ledger.frameCompleted(frame, shown: true) }
        // The pane was hidden: the host's numbering resumes far ahead.
        var reports: [Int64] = []
        for frame in UInt32(5_000)..<5_000 + window {
            if let percent = ledger.frameCompleted(frame, shown: true) { reports.append(percent) }
        }
        // A new stream numbers from 0 again.
        for frame in UInt32(0)..<window {
            if let percent = ledger.frameCompleted(frame, shown: true) { reports.append(percent) }
        }
        #expect(reports == [0, 0])
    }

    // MARK: input to present

    @Test func aShownFrameTimesEachInputItShowsForTheFirstTime() {
        var ledger = RemoteStreamPresentLedger()
        #expect(ledger.newlyShownInputs(echo: 0) == nil)
        #expect(ledger.newlyShownInputs(echo: 3) == 1...3)
        #expect(ledger.newlyShownInputs(echo: 3) == nil)
        #expect(ledger.newlyShownInputs(echo: 5) == 4...5)
        let capacity = UInt32(RemoteInputLatency.capacity)
        #expect(ledger.newlyShownInputs(echo: 5 + 2 * capacity) == (6 + capacity)...(5 + 2 * capacity))
    }

    @Test func presentLogWritesDecodedAndPresentPointsAndSkipsUnshownFrames() {
        let runtime = recordingRuntime()
        let latency = RemoteInputLatency(runtime: runtime, clock: fixedClock(micros: 1_000))
        let log = RemotePresentLog(inputLatency: latency)
        latency.recordSent(1)
        log.frameDecoded(0)
        log.frameDecoded(1)
        #expect(records(runtime) == 3)
        var recorder = RemotePresentLog.Recorder(inputLatency: latency)
        recorder.presentCompleted(frame: 0, echo: 1, presentedAt: 0.004)
        recorder.presentCompleted(frame: 1, echo: 1, presentedAt: 0)
        #expect(records(runtime) == 4)
    }

    // MARK: the mock host's echo

    #if DEBUG
    @MainActor @Test func mockHostFramesEchoTheNewestInputTheViewerSent() async throws {
        let host = MockRemoteStreamSource(width: 640, height: 400)
        try #require(host.canEncode, "VideoToolbox has no H.264 encoder here")
        let units = host.accessUnits()
        let controller = RemoteInputController(inputLatency: RemoteInputLatency(runtime: recordingRuntime()))
        let sink = MockRemoteInputSink(host: host)
        controller.sink = sink
        controller.isActive = true
        // Input 1 (text) paints nothing; input 2 moves the pointer, and the frame it paints is captured after both.
        controller.commitText("a")
        controller.pointer((x: 40, y: 50))
        var echo: UInt32?
        for await unit in units {
            echo = unit.inputEcho
            break
        }
        #expect(echo == 2)
        #expect(controller.inputLatency.sentMicros(2) != nil)
    }
    #endif
}
