import CmuxNextCompat
import CmuxNextMetrics
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

    /// A metrics file on `runtime`, which the present log's histograms go to.
    private func attachMetrics(to runtime: TraceRuntime) -> MetricsStore {
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "nightly", osVersion: "26.1.0",
                                     hardwareClass: "Mac16,10", buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242)
        #expect(store.attach(to: runtime))
        return store
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

    @Test func echoKeepsOnlyTheInputsThatChangedThePicture() {
        var echo = RemoteInputEcho.noInput
        #expect(Array(echo).isEmpty)
        echo.inputDamaged(0)
        echo.inputDamaged(2)
        echo.inputDamaged(5)
        #expect(echo.newest == 5)
        #expect(Array(echo) == [5, 2])
        // An input applied out of order still marks its own bit.
        echo.inputDamaged(3)
        #expect(Array(echo) == [5, 3, 2])
        let capacity = UInt32(RemoteInputLatency.capacity)
        echo.inputDamaged(5 + capacity)
        #expect(Array(echo) == [5 + capacity], "inputs older than the send table were kept")
    }

    @Test func aShownFrameTimesEachInputItShowsForTheFirstTime() {
        var host = RemoteInputEcho.noInput
        var ledger = RemoteStreamPresentLedger()
        #expect(Array(ledger.newlyShownInputs(echo: host)).isEmpty)
        // Inputs 2 and 4 changed nothing: they are never in an echo.
        host.inputDamaged(1)
        host.inputDamaged(3)
        #expect(Array(ledger.newlyShownInputs(echo: host)) == [3, 1])
        // A later frame that changed by itself (a cursor blink) shows nothing new.
        #expect(Array(ledger.newlyShownInputs(echo: host)).isEmpty)
        // The frame that showed input 5 was never shown; the next shown frame shows 5 and 6 first.
        host.inputDamaged(5)
        host.inputDamaged(6)
        #expect(Array(ledger.newlyShownInputs(echo: host)) == [6, 5])
    }

    /// The present log's samples and its `remote.present` record. Input 1 changed nothing and input 2 moved the
    /// pointer, both sent at 1_000 us; the frame that shows input 2 is shown at 0.004 s. Exactly one
    /// `remote.input_to_present` sample, 3_000 us, and `remote.present` carries the display's time, not the
    /// time it was written. Then a window of 100 host frames, 5 never presented and 3 never shown, records one
    /// `smoothness.dropped_pct.remote_stream` sample, 8%, and no further latency sample.
    @Test func presentLogRecordsOneSamplePerDamagingInputAtTheDisplaysTime() throws {
        let log = RecordLog()
        let runtime = log.runtime()
        let store = attachMetrics(to: runtime)
        let latency = RemoteInputLatency(runtime: runtime, clock: fixedClock(micros: 1_000))
        latency.recordSent(1)
        latency.recordSent(2)
        let presentLog = RemotePresentLog(inputLatency: latency)
        presentLog.frameDecoded(0)
        #expect(log.records.count == 3)

        var host = RemoteInputEcho.noInput
        host.inputDamaged(2)
        var recorder = RemotePresentLog.Recorder(inputLatency: latency)
        recorder.presentCompleted(frame: 0, echo: host, presentedAt: 0.004)
        let written = Array(log.records.dropFirst(3))
        #expect(written.count == 1)
        let present = try #require(written.first)
        #expect(present.phase == .instant)
        #expect(present.tNanos == 4_000_000, "remote.present was stamped when it was written, not when it was shown")
        #expect(present.arg0 == 0 && present.arg1 == 2)

        let window = RemoteStreamPresentLedger.windowFrames
        for frame in UInt32(1)..<window where !(10..<15).contains(frame) {
            let shownAt = (20..<23).contains(frame) ? 0 : 0.004 + Double(frame) / 60
            recorder.presentCompleted(frame: frame, echo: host, presentedAt: shownAt)
        }
        #expect(log.records.count == 3 + 92, "a frame the display never showed wrote remote.present")

        let delta = store.delta()
        let inputToPresent = try #require(delta.histograms.first { $0.name == HistogramID.remoteInputToPresent.name })
        #expect(inputToPresent.count == 1, "an input that changed nothing, or one already shown, was timed")
        #expect(inputToPresent.sum == 3_000)
        let dropped = try #require(delta.histograms.first {
            $0.name == HistogramID.smoothnessDroppedPercent(.remoteStream).name
        })
        #expect(dropped.count == 1)
        #expect(dropped.sum == 8, "8 of 100 host frames not shown is 8%")
    }

    // MARK: the mock host's echo

    #if DEBUG
    @MainActor @Test func mockHostFramesEchoOnlyTheInputsThatChangedThePicture() async throws {
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
        var echo: RemoteInputEcho?
        for await unit in units {
            echo = unit.inputEcho
            break
        }
        #expect(echo.map { Array($0) } == [2], "the echo holds an input that changed nothing")
        #expect(controller.inputLatency.sentMicros(2) != nil)
    }
    #endif
}

/// The records a test runtime writes, in order.
private nonisolated final class RecordLog: Sendable {
    private let state = Mutex<[TraceRuntime.StubRecord]>([])

    var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

    /// A runtime with every category on that records into this log.
    func runtime() -> TraceRuntime {
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
            state.withLock { $0.append(record) }
        })
        runtime.setCategoryMask(.max)
        return runtime
    }
}
