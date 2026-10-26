import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
@testable import CmuxNextWakeups
import Testing

/// A new terminal's once-per-create stages write `create.tab` instants in every build (p09-observability task 043),
/// and only for a create: keyed by its intent id (`arg1`, flagged as an async id), the stage and its value in `arg0`.
/// A restore, a reattach, another kind's create or an ended create writes nothing. DEBUG builds also mark the same
/// attach stages on an armed `debug.new_terminal_trace` run.
struct NewTerminalTraceStageTests {
    /// The records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        /// The `create.tab` instants (an interval's begin and end records left out).
        var instants: [TraceRuntime.StubRecord] {
            records.filter { $0.name == SignpostName.createTab.rawValue && $0.phase == .instant }
        }

        /// A runtime with only the categories in `mask` on, recording into this log.
        func runtime(mask: UInt64 = 1 << UInt64(SignpostCategory.create.traceBit)) -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(mask)
            return runtime
        }
    }

    /// Something with an identity, for a session.
    private final class Token {}

    @Test("A stage is one create.tab instant keyed by its create's intent id, the stage and its value in arg0")
    func stageIsKeyedToItsCreate() {
        let log = RecordLog()
        let trace = NewTerminalTrace(trace: log.runtime())
        trace.attachEvent(.attachStart, surface: 7, intent: 42)
        trace.event(.requestSent, intent: 42)

        #expect(log.records.count == 2)
        #expect(log.instants.count == 2)
        #expect(log.records.allSatisfy { $0.flags.contains(.asyncID) && $0.arg1 == 42 })
        #expect(log.records.map(\.arg0) == [21 | 7 << 8, 17])
    }

    @Test("A restore, a reattach or a retry carries no intent and writes no create.tab instant")
    func noCreateWritesNothing() {
        let log = RecordLog()
        let trace = NewTerminalTrace(trace: log.runtime())
        trace.attachEvent(.attachStart, surface: 7, intent: 0) // a restored view's attach
        trace.event(.finalGrid, intent: 0, value: 1)
        let first = NewTerminalTrace.FirstAttach(intent: 42)
        #expect(first.take() == 42)
        trace.attachEvent(.attachEnd, surface: 7, intent: first.take()) // the same view's reattach
        #expect(first.take() == 0)
        #expect(log.records.isEmpty)
    }

    @Test("With the create category off a stage writes nothing")
    func categoryOffWritesNothing() {
        let log = RecordLog()
        let trace = NewTerminalTrace(trace: log.runtime(mask: 0))
        trace.attachEvent(.attachStart, surface: 7, intent: 42)
        trace.event(.surfaceCreated, intent: 42)
        #expect(log.records.isEmpty)
    }

    @MainActor
    @Test("A main-actor stage writes only while its new terminal's interval is open")
    func intervalStagesWriteWhileOpen() {
        let log = RecordLog()
        let runtime = log.runtime()
        let trace = NewTerminalTrace(trace: runtime)
        let signposter = Signposter(category: .create, trace: runtime)
        let terminal = CreateTabInterval(kind: .terminal, signposter: signposter)
        let page = CreateTabInterval(kind: .chromium, signposter: signposter)
        let stages = NewTerminalTrace.CreateStages(terminal, trace: trace)

        stages.event(.surfaceCreated, value: 9)
        stages.event(.finalGrid, value: NewTerminalTrace.gridValue(columns: 120, rows: 40))
        trace.event(.reply, of: page, value: 9) // another kind's create
        trace.event(.reply, of: nil, value: 9)
        terminal.end(.shown)
        stages.event(.finalGrid, value: 1) // after the first frame: a resize, no create stage

        #expect(terminal.intentID != 0)
        #expect(log.instants.map(\.arg1) == [terminal.intentID, terminal.intentID])
        #expect(log.instants.map(\.arg0) == [20 | 9 << 8, 29 | (120 << 24 | 40) << 8])
    }

    @MainActor
    @Test("A view's stages end with its interval: the tie is weak")
    func stagesDoNotKeepTheInterval() {
        let log = RecordLog()
        let runtime = log.runtime()
        let trace = NewTerminalTrace(trace: runtime)
        var interval: CreateTabInterval? = CreateTabInterval(kind: .terminal, signposter: Signposter(category: .create, trace: runtime))
        let stages = NewTerminalTrace.CreateStages(interval, trace: trace)
        interval = nil
        stages.event(.finalGrid, value: 1)
        #expect(log.instants.isEmpty)
    }

    @MainActor
    @Test("The cache finds a new tab's open interval by its tab or its unlisted surface; listing returns the surface's")
    func waitingIntervalLookup() {
        let runtime = RecordLog().runtime()
        let timings = CreateTabTimings(signposter: Signposter(category: .create, trace: runtime), afterCommit: { _ in })
        let made = timings.begin(.terminal)
        timings.expect(made, surface: 9)
        #expect(timings.waitingInterval(.terminal, tab: "t", surface: 9) === made)
        #expect(timings.waitingInterval(.chromium, tab: "t", surface: 9) == nil, "another kind's view")
        #expect(timings.waitingInterval(.terminal, tab: "t", surface: 8) == nil, "a restored tab waits for nothing")
        #expect(timings.listed(surface: 9, tab: "t") === made)
        #expect(timings.listed(surface: 9, tab: "t") == nil, "listed once")
        #expect(timings.waitingInterval(.terminal, tab: "t", surface: 0) === made)
        let standIn = timings.begin(.terminal)
        timings.expect(standIn, tab: "s", standIn: false)
        #expect(timings.waitingInterval(.terminal, tab: "s", surface: 0) === standIn)
        timings.released("t")
        #expect(timings.waitingInterval(.terminal, tab: "t", surface: 9) == nil, "an ended interval is no create")
    }

    @Test("Stage codes are fixed and above every create.tab kind code")
    func stageCodesAreFixedAndDisjointFromKinds() {
        #expect(NewTerminalTrace.Mark.allCases.map(\.traceCode) == Array(UInt64(16)...29))
        let kinds = CreateTabInterval.Kind.allCases.map(\.traceCode)
        #expect(kinds.allSatisfy { $0 < NewTerminalTrace.Mark.action.traceCode })
    }

    @Test("A grid packs the columns above the rows, each clamped to 24 bits")
    func gridValue() {
        #expect(NewTerminalTrace.gridValue(columns: 80, rows: 24) == 80 << 24 | 24)
        #expect(NewTerminalTrace.gridValue(columns: -1, rows: 1 << 30) == (1 << 24) - 1)
        #expect(NewTerminalTrace.stageArg(.finalGrid, value: NewTerminalTrace.gridValue(columns: 1 << 30, rows: 1 << 30)) >> 8
            == (1 << 48) - 1)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    @Test("An armed run marks the bound terminal's attach and final grid; only a create's attach writes instants")
    func armedRunMarksTheBoundTerminal() {
        let log = RecordLog()
        let trace = NewTerminalTrace(trace: log.runtime())
        let (io, session, other) = (Token(), Token(), Token())
        #expect(trace.begin())
        trace.markAction()
        trace.bind(terminal: "t1")
        trace.tabAdded(terminal: "t1", surface: 7)
        trace.attachEvent(.attachStart, surface: 8, intent: 0) // another terminal's attach
        trace.attachEvent(.attachEnd, surface: 7, intent: 42)
        trace.watch(io: ObjectIdentifier(io), surface: 7)
        #expect(trace.sessionCreated(io: ObjectIdentifier(io), session: ObjectIdentifier(session), lane: nil, layer: nil))
        trace.mark(.finalGrid, session: ObjectIdentifier(other))
        trace.mark(.finalGrid, session: ObjectIdentifier(session))
        let record = trace.finish(timedOut: false)

        #expect(record?.milliseconds(.action) == 0)
        #expect(record?.milliseconds(.attachStart) == nil, "surface 8 is not the traced terminal's")
        #expect(record?.milliseconds(.attachEnd) != nil)
        #expect(record?.milliseconds(.surfaceCreated) != nil)
        #expect(record?.milliseconds(.finalGrid) != nil)
        #expect(log.records.map(\.arg0) == [23 | 7 << 8], "only the create's attach wrote an instant")
    }
    #endif
}
