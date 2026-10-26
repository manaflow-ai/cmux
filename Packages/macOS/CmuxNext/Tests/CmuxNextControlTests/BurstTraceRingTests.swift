import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// The burst marks in every build (p09-observability task 044): with the `burst` trace category on, each mark is
/// one `burst.event` ring instant, with no `debug.burst start`, so a Release recording carries them; with it off
/// and no `debug.burst` recording, a mark writes nothing.
@Suite struct BurstTraceRingTests {
    /// The records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        /// A runtime recording into this log, with only `categories` on.
        func runtime(_ categories: [SignpostCategory]) -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(categories.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
            return runtime
        }
    }

    @Test("With the burst category off and no debug.burst recording, a mark writes nothing")
    func offWritesNothing() {
        let log = RecordLog()
        let trace = BurstTrace(trace: log.runtime([.create]))
        #expect(!trace.isArmed)
        trace.mark(.refusal, input: 1)
        trace.closed(tabs: ["a"], emptiesPane: false, input: 1)
        trace.gridSent(surface: 1, cols: 80, rows: 24, expectsEcho: true)
        trace.gridAnnounced(surface: 1, cols: 80, rows: 24)
        trace.output(surface: 1)
        #expect(log.records.isEmpty)
        #expect(trace.awaitingOutputCount == 0)
    }

    @Test("With the burst category on, each mark is one burst.event instant with its kind and numbers")
    func eachMarkIsOneInstant() throws {
        let log = RecordLog()
        let trace = BurstTrace(trace: log.runtime([.burst]))
        #expect(trace.isArmed)
        trace.mark(.refusal, input: 2.5)
        trace.closed(tabs: ["tab_1", "tab_2"], emptiesPane: true, input: nil)
        trace.output(surface: 7)  // no grid yet: not a first output
        trace.gridSent(surface: 7, cols: 100, rows: 30, expectsEcho: true)
        trace.gridAnnounced(surface: 7, cols: 120, rows: 30)  // another client's grid: no echo
        trace.gridAnnounced(surface: 7, cols: 100, rows: 30)
        trace.output(surface: 7)
        trace.output(surface: 7)  // after the first: nothing
        let records = log.records
        #expect(records.allSatisfy { $0.name == SignpostName.burstEvent.rawValue && $0.phase == .instant })
        #expect(records.allSatisfy { $0.categoryBit == SignpostCategory.burst.traceBit })
        #expect(records.map { $0.arg0 & 0xFF } == [1, 4, 5, 6, 7])
        try #require(records.count == 5)
        #expect(records[0].arg1 == 2_500_000_000, "a press mark's arg1 is its input event time in ns")
        #expect(records[1].arg0 == 4 | 2 << 8 | 1 << 24 && records[1].arg1 == 0)
        #expect(records[2].arg0 == 5 | 100 << 8 | 30 << 24 | 1 << 40 && records[2].arg1 == 7)
        #expect(records[3].arg0 == 6 | 100 << 8 | 30 << 24 && records[3].arg1 == 7)
        #expect(records[4].arg0 == 7 && records[4].arg1 == 7)
    }

    @Test("Each kind keeps its fixed ring code")
    func kindCodesArePinned() {
        let kinds: [BurstTrace.Kind] = [.refusal, .closeSwallowed, .creationCancelled, .closed, .ptyGrid, .gridEcho,
                                        .firstOutput]
        #expect(kinds.map(\.traceCode) == Array(1...7))
    }

    @Test("A count past its 16-bit field saturates and leaves the next field alone")
    func fieldsSaturate() {
        let log = RecordLog()
        let trace = BurstTrace(trace: log.runtime([.burst]))
        trace.gridSent(surface: 3, cols: 70_000, rows: -1, expectsEcho: false)
        #expect(log.records.map(\.arg0) == [5 | 0xFFFF << 8])
    }
}
