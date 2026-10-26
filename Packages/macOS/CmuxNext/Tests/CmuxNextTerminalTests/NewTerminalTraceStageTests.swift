import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
@testable import CmuxNextWakeups
import Testing

/// A new terminal's once-per-terminal stages write `create.tab` instants in every build (p09-observability
/// task 043): the stage in `arg0`, the daemon surface or the grid in `arg1`; with the `create` category off
/// they write nothing. DEBUG builds also mark the same stages on an armed `debug.new_terminal_trace` run.
struct NewTerminalTraceStageTests {
    /// The records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        /// A runtime with only the categories in `mask` on, recording into this log.
        func runtime(mask: UInt64 = 1 << UInt64(SignpostCategory.create.traceBit)) -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(mask)
            return runtime
        }
    }

    /// Something with an identity, for a session or an IO.
    private final class Token {}

    @Test("Each stage mark point writes one create.tab instant with its stage and key")
    func eachStageIsOneCreateTabInstant() {
        let log = RecordLog()
        let trace = NewTerminalTrace(trace: log.runtime())
        let session = Token()
        trace.markAction()
        trace.mark(.attachStart, surface: 7)
        trace.mark(.attachReplied, surface: 7)
        trace.mark(.attachEnd, surface: 7)
        trace.event(.surfaceCreated)
        trace.event(.finalGrid, session: ObjectIdentifier(session), arg1: NewTerminalTrace.gridBits(columns: 120, rows: 40))

        #expect(log.records.allSatisfy { $0.name == SignpostName.createTab.rawValue && $0.phase == .instant })
        #expect(log.records.map(\.arg0) == [16, 21, 22, 23, 20, 29])
        #expect(log.records.map(\.arg1) == [0, 7, 7, 7, 0, 120 << 32 | 40])
    }

    @Test("With the create category off a stage writes nothing")
    func categoryOffWritesNothing() {
        let log = RecordLog()
        let trace = NewTerminalTrace(trace: log.runtime(mask: 0))
        trace.markAction()
        trace.mark(.attachStart, surface: 7)
        trace.event(.surfaceCreated)
        #expect(log.records.isEmpty)
    }

    @Test("Stage codes are fixed and above every create.tab kind code")
    func stageCodesAreFixedAndDisjointFromKinds() {
        #expect(NewTerminalTrace.Mark.allCases.map(\.traceCode) == Array(UInt64(16)...29))
        let kinds = CreateTabInterval.Kind.allCases.map(\.traceCode)
        #expect(kinds.allSatisfy { $0 < NewTerminalTrace.Mark.action.traceCode })
    }

    @Test("A grid packs the columns high and the rows low, clamped to 32 bits")
    func gridBits() {
        #expect(NewTerminalTrace.gridBits(columns: 80, rows: 24) == 80 << 32 | 24)
        #expect(NewTerminalTrace.gridBits(columns: -1, rows: Int(UInt32.max) + 5) == UInt64(UInt32.max))
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    @Test("An armed run marks the bound terminal's stages through the same mark points; others only write instants")
    func armedRunMarksTheBoundTerminal() {
        let log = RecordLog()
        let trace = NewTerminalTrace(trace: log.runtime())
        let (io, session, other) = (Token(), Token(), Token())
        #expect(trace.begin())
        trace.markAction()
        trace.bind(terminal: "t1")
        trace.tabAdded(terminal: "t1", surface: 7)
        trace.mark(.attachStart, surface: 8) // another terminal's attach
        trace.mark(.attachEnd, surface: 7)
        trace.watch(io: ObjectIdentifier(io), surface: 7)
        #expect(trace.sessionCreated(io: ObjectIdentifier(io), session: ObjectIdentifier(session), lane: nil, layer: nil))
        trace.event(.finalGrid, session: ObjectIdentifier(other), arg1: 1)
        trace.event(.finalGrid, session: ObjectIdentifier(session), arg1: 2)
        let record = trace.finish(timedOut: false)

        #expect(record?.milliseconds(.action) == 0)
        #expect(record?.milliseconds(.attachStart) == nil, "surface 8 is not the traced terminal's")
        #expect(record?.milliseconds(.attachEnd) != nil)
        #expect(record?.milliseconds(.surfaceCreated) != nil)
        #expect(record?.milliseconds(.finalGrid) != nil)
        #expect(log.records.map(\.arg0) == [16, 21, 23, 29, 29], "every mark point wrote its instant, traced or not")
    }
    #endif
}
