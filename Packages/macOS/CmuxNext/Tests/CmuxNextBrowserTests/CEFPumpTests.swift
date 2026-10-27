@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextMetrics
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import CmuxNextWakeups
import Foundation
import Testing

/// The pump's `cef.pump` slice (p09-observability task 032): each `CefDoMessageLoopWork` pass is one B/E pair in
/// the trace ring while a recording has `cef` and `task` on (never in the black box), its begin holding why the pass ran and its end whether it used
/// CEF's whole time slice and its time in us, on the pump's monotonic clock (the wall-clock `tab-switch` pump log
/// is gone). The pump runs on a hand-fired timer and a hand-moved clock; each test records into its own runtime.
@MainActor
@Suite struct CEFPumpTests {
    /// The records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        func runtime() -> TraceRuntime {
            TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
        }

        /// The `cef.pump` records with `phase`.
        func pump(_ phase: TraceRuntime.Phase) -> [TraceRuntime.StubRecord] {
            records.filter { $0.name == SignpostName.cefPump.rawValue && $0.phase == phase }
        }
    }

    final class Timer: CEFPumpTimer {
        var onFire: (() -> Void)?
        var armed: TimeInterval?
        func arm(after delay: TimeInterval, tolerance: TimeInterval) { armed = delay }
        func disarm() { armed = nil }
        func invalidate() { armed = nil }
        func fire() { armed = nil; onFire?() }
    }

    /// A pump on its own trace runtime, started; `work` runs inside each pass and `seconds` is the pump's clock.
    final class Rig {
        let timer = Timer()
        let log = RecordLog()
        let runtime: TraceRuntime
        let gate = CEFPumpCrossThreadGate(ledger: WakeupLedger())
        var seconds: TimeInterval = 100
        var work: () -> Void = {}
        private(set) var pump: CEFMessagePump!

        /// `categories`: the trace categories on (default: a recording's `cef` and `task`).
        init(categories: TraceCategories = [.cef, .task]) {
            runtime = log.runtime()
            runtime.setCategories(categories)
            let signposter = Signposter(category: .cef, mirror: SignpostMetricKitMirror(), trace: runtime)
            pump = CEFMessagePump(work: { [unowned self] in self.work() }, timer: timer, clock: { [unowned self] in self.seconds },
                                  ledger: WakeupLedger(), gate: gate, signposter: signposter)
            pump.start()
        }

        /// A CEF delayed request, then its fire date's pass.
        func delayedPass(milliseconds: Int64) {
            pump.request(milliseconds: milliseconds)
            seconds += TimeInterval(milliseconds) / 1_000
            timer.fire()
        }
    }

    // Binary fractions of a second, exact in a Double at 100 s: 3906.25 us and 15625 us.
    nonisolated private static let shortPass: TimeInterval = 1.0 / 256
    nonisolated private static let longPass: TimeInterval = 1.0 / 64

    @Test func eachPassIsOneSliceWithItsReasonLengthAndTime() {
        let rig = Rig()
        rig.work = { rig.seconds += Self.shortPass }
        rig.timer.fire() // the start's immediate pass
        rig.delayedPass(milliseconds: 7)
        rig.work = { rig.seconds += Self.longPass }
        rig.pump.request(milliseconds: 10)
        #expect(!rig.gate.admit(delayMilliseconds: 50, nowNanos: UInt64(rig.seconds * 1e9)), "kept: the armed +10 ms comes first")
        rig.seconds += 0.010
        rig.timer.fire() // CEF's +10 ms
        rig.seconds += 0.040
        rig.timer.fire() // the kept +50 ms
        rig.work = {}
        rig.pump.pumpNow() // the quit path's drain: no timer armed it

        let begins = rig.log.pump(.begin)
        let ends = rig.log.pump(.end)
        #expect(begins.map(\.arg0) == [1, 2, 2, 3, 0], "now, delayed, delayed, kept, the drain")
        #expect(begins.allSatisfy { $0.arg1 == 0 })
        #expect(ends.map(\.arg0) == [0, 0, 1, 1, 0], "the passes that used CEF's 10 ms slice are long")
        #expect(ends.map(\.arg1) == [3906, 3906, 15625, 15625, 0], "elapsed us on the pump's clock")
        #expect(rig.log.records.map(\.phase) == Array(repeating: [.begin, .end], count: 5).flatMap { $0 }, "B/E pairs, never nested")
        #expect(rig.pump.stats.workRuns == 5)
        #expect(rig.pump.stats.longWorkRuns == 2, "the counter and the slice agree")
    }

    @Test func aFireInsideAPassWritesNoSliceOfItsOwn() {
        let rig = Rig()
        rig.timer.fire()
        var nested = true
        rig.work = {
            guard nested else { return }
            nested = false
            rig.timer.fire() // a menu's tracking loop inside CefDoMessageLoopWork
        }
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.pump.stats.reentrantFires == 1)
        #expect(rig.log.pump(.begin).count == 2, "the start's pass and the outer one")
        #expect(rig.log.pump(.end).count == 2)
        rig.timer.fire() // the deferred pass
        rig.pump.scheduleNow()
        rig.timer.fire() // a plain immediate pass after it
        #expect(rig.log.pump(.begin).map(\.arg0) == [1, 1, 4, 1], "4: the pass that runs the fire the nested loop deferred")
        #expect(rig.log.records.map(\.phase) == Array(repeating: [.begin, .end], count: 4).flatMap { $0 })
    }

    @Test(arguments: [TraceCategories.task, TraceCategories.blackBox, []])
    func withoutBothCefAndTaskTheRingTakesNoPassAndTheCountersStillRun(categories: TraceCategories) {
        let rig = Rig(categories: categories)
        rig.work = { rig.seconds += Self.shortPass }
        rig.timer.fire()
        rig.work = { rig.seconds += Self.longPass }
        rig.delayedPass(milliseconds: 7)
        #expect(rig.log.records.isEmpty, "the black box (cef on, task off) takes no pass, short or long")
        #expect(rig.runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        #expect(rig.pump.stats.workRuns == 2)
        #expect(rig.pump.stats.longWorkRuns == 1)
    }

    @Test func aRecordingStoppedMidPassStillEndsItsSlice() {
        let rig = Rig()
        rig.work = { rig.runtime.setCategoryMask(0) } // trace.stop inside CefDoMessageLoopWork
        rig.timer.fire()
        #expect(rig.log.records.map(\.phase) == [.begin, .end], "a written B always gets its E")
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.log.records.count == 2, "the next pass, with the recording off, writes nothing")
    }

    @Test func aRecordingStartedMidPassWritesNoEndForThatPass() {
        let rig = Rig(categories: .blackBox)
        rig.work = { rig.runtime.setCategories([.cef, .task]) } // trace.start inside CefDoMessageLoopWork
        rig.timer.fire()
        #expect(rig.log.records.isEmpty, "an unwritten B gets no E")
        rig.work = {}
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.log.records.map(\.phase) == [.begin, .end], "the next pass records")
    }

    @Test func aPassIsNotMirroredToMetricKit() {
        #expect(!SignpostMetricKitMirror.mirrors(.cefPump))
    }

    @Test func theReasonCodesAreFixedAndNonzero() {
        #expect(CEFMessagePump.LedgerReason.allCases.map(\.traceCode) == [1, 2, 3, 4])
    }

    @Test func recordWorkRunCountsTheSliceAsLong() {
        var stats = CEFPumpStats()
        let metrics = Metrics(runtime: TraceRuntime(role: .app)) // no store: records nothing
        // recordWorkRun is mutating; #expect's expansion would call it on an immutable copy.
        let halfSliceIsLong = stats.recordWorkRun(elapsed: CEFPumpSchedule.timeSlice / 2, metrics: metrics)
        #expect(!halfSliceIsLong)
        let fullSliceIsLong = stats.recordWorkRun(elapsed: CEFPumpSchedule.timeSlice, metrics: metrics)
        #expect(fullSliceIsLong)
        #expect(stats.workRuns == 2)
        #expect(stats.longWorkRuns == 1)
        #expect(stats.workSeconds == CEFPumpSchedule.timeSlice * 1.5)
    }
}
