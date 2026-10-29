import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import os
import Testing

/// The records a test runtime writes, in order, each stamped from a clock that advances 10 ns per read: until
/// task 003's decoder lands, the stub's recorder hands over the fields a ring record would hold.
private final class RecordLog: Sendable {
    private let state = Mutex<(records: [TraceRuntime.StubRecord], tick: UInt64)>(([], 0))

    var records: [TraceRuntime.StubRecord] { state.withLock { $0.records } }

    /// A runtime that records into this log, with every category off.
    func runtime() -> TraceRuntime {
        let clock = TraceClock(reader: .init(uptimeNanos: { [self] in
            state.withLock { state in
                state.tick += 10
                return state.tick
            }
        }, continuousNow: { ContinuousClock.now }))
        return TraceRuntime(role: .app, clock: clock, stubRecorder: { [self] record in
            state.withLock { $0.records.append(record) }
        })
    }
}

/// ``Signposter`` writes every begin, end, event and flow hop to the trace ring under its name's category flag
/// (p09-observability task 006). Each test makes its own ``TraceRuntime`` and mirror, so suites running in
/// parallel never see another's flags or records.
struct SignposterTraceRingTests {
    private let mirror = SignpostMetricKitMirror()
    private let message = ActionSignpostMessage(id: "test.action", origin: "user", inputAgeMilliseconds: 1.5)

    private func signposter(_ category: SignpostCategory, _ runtime: TraceRuntime) -> Signposter {
        Signposter(category: category, mirror: mirror, trace: runtime)
    }

    private func records(_ runtime: TraceRuntime) -> UInt64 { runtime.stubRecordCount.load(ordering: .relaxed) }

    private func enable(_ runtime: TraceRuntime, _ categories: SignpostCategory...) {
        runtime.setCategoryMask(categories.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
    }

    private func asyncID(_ interval: SignpostInterval) -> UInt64? {
        guard case .async(let id)? = interval.ring else { return nil }
        return id
    }

    /// Runs every public emit method once: 10 intervals (20 records) and 3 events.
    private func emitEverything(_ runtime: TraceRuntime) {
        let action = signposter(.action, runtime)
        action.end(.actionPerform, action.begin(.actionPerform, "id=test"))
        action.end(.actionPerform, action.begin(.actionPerform, message))
        action.end(.actionCommit, action.begin(.actionCommit, message, actionIndex: 3, entrypoint: 1), .committed)
        action.end(.actionCommit, action.begin(.actionCommit, message), .missed)
        action.endSpanningNestedLoop(.actionGate, action.begin(.actionGate, message))
        #expect(action.interval(.actionPerform, "id=test") { 1 } == 1)
        #expect(action.interval(.actionPerform, message) { 2 } == 2)
        let key = signposter(.key, runtime)
        key.end(.scrollToFrame, key.begin(.scrollToFrame, scrollPhase: .changed, ageMilliseconds: 0.25), .committed,
                scrollTarget: .layout)
        key.flowHop(.appKeyDispatch, flow: 42, ageMicroseconds: 120)
        let stall = signposter(.stall, runtime)
        stall.end(.stallMainTask, stall.begin(.stallMainTask, taskClass: "visible", owner: "test", classID: 2, ownerID: 9))
        stall.event(.stallOverBudget, "class=visible")
        stall.event(.stallOverBudget, "class=visible", arg0: 7, arg1: 8)
        let launch = signposter(.launch, runtime)
        launch.end(.launchStartupTask, launch.begin(.launchStartupTask, "name=Test.step priority=critical", arg0: 1))
    }

    @Test("With the categories off, no emit method writes a record")
    func offWritesNothing() {
        let runtime = TraceRuntime(role: .app)
        emitEverything(runtime)
        #expect(records(runtime) == 0)
        let interval = signposter(.action, runtime).begin(.actionCommit, message)
        #expect(!interval.isTraced)
        signposter(.action, runtime).end(.actionCommit, interval, .committed)
        #expect(records(runtime) == 0)
    }

    @Test("With the categories on, every begin, end, event and flow hop writes one record")
    func onWritesEveryEmit() {
        let runtime = TraceRuntime(role: .app)
        enable(runtime, .action, .key, .stall, .launch)
        emitEverything(runtime)
        #expect(records(runtime) == 10 * 2 + 3)
    }

    @Test("A name records only under its own category's flag")
    func flagIsPerCategory() {
        let runtime = TraceRuntime(role: .app)
        enable(runtime, .key)
        let action = signposter(.action, runtime)
        action.end(.actionPerform, action.begin(.actionPerform, message))
        #expect(records(runtime) == 0)
        signposter(.key, runtime).flowHop(.appIOWrite, flow: 1)
        #expect(records(runtime) == 1)
    }

    @Test("An end writes only for a begin that wrote: no end without its begin")
    func endFollowsItsBegin() {
        let runtime = TraceRuntime(role: .app)
        let action = signposter(.action, runtime)
        let untraced = action.begin(.actionCommit, message)
        enable(runtime, .action)
        action.end(.actionCommit, untraced, .committed)
        #expect(records(runtime) == 0)
        let traced = action.begin(.actionCommit, message)
        #expect(traced.isTraced)
        action.end(.actionCommit, traced, .committed)
        #expect(records(runtime) == 2)
    }

    @Test("A begin recorded before its category turned off still writes its end: 2 records, B/E and AB/AE")
    func endOfARecordedBeginIgnoresTheFlag() {
        let log = RecordLog()
        let runtime = log.runtime()
        enable(runtime, .action)
        let action = signposter(.action, runtime)
        let commit = action.begin(.actionCommit, message)
        let perform = action.begin(.actionPerform, message)
        runtime.setCategoryMask(0)
        action.end(.actionPerform, perform)
        action.end(.actionCommit, commit, .committed)
        #expect(log.records.map(\.phase) == [.asyncBegin, .begin, .end, .asyncEnd])
        #expect(records(runtime) == 4)
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.action.traceBit))
        runtime.interval(.actionPerform, arg0: 0) { runtime.setCategoryMask(0) }
        #expect(log.records.suffix(2).map(\.phase) == [.begin, .end])
        #expect(records(runtime) == 6)
    }

    @Test("action.commit decodes as AB then AE with one name, its id in arg1, the asyncID flag and rising t")
    func actionCommitRecordsDecodeAsAnAsyncSlice() throws {
        let log = RecordLog()
        let runtime = log.runtime()
        enable(runtime, .action)
        let action = signposter(.action, runtime)
        let commit = action.begin(.actionCommit, message, actionIndex: 5, entrypoint: 0)
        let id = try #require(asyncID(commit))
        action.end(.actionCommit, commit, .missed)
        let records = log.records
        try #require(records.count == 2)
        let (begin, end) = (records[0], records[1])
        #expect(begin.phase == .asyncBegin && end.phase == .asyncEnd)
        #expect(begin.name == SignpostName.actionCommit.rawValue && end.name == begin.name)
        #expect(begin.categoryBit == SignpostCategory.action.traceBit && end.categoryBit == begin.categoryBit)
        #expect(begin.arg1 == id && end.arg1 == id)
        #expect(begin.flags.contains(.asyncID) && end.flags.contains(.asyncID))
        #expect(begin.tNanos < end.tNanos)
        #expect(begin.arg0 & 0xFFFF_FFFF == 5)
        #expect(begin.arg0 >> 32 & 0xFF == 1, "entrypoint position 0 is stored as code 1")
        #expect(begin.arg0 >> 40 == 1_500, "the input age in us")
        #expect(end.arg0 == Signposter.EndCode.missed)
    }

    @Test("action.perform decodes as B then E with one name and no async id")
    func actionPerformRecordsDecodeAsAThreadSlice() throws {
        let log = RecordLog()
        let runtime = log.runtime()
        enable(runtime, .action)
        let action = signposter(.action, runtime)
        action.endSpanningNestedLoop(.actionPerform, action.begin(.actionPerform, message, actionIndex: 2, entrypoint: 3))
        let records = log.records
        try #require(records.count == 2)
        #expect(records.map(\.phase) == [.begin, .end])
        #expect(records.allSatisfy { $0.name == SignpostName.actionPerform.rawValue && !$0.flags.contains(.asyncID) })
        #expect(records[0].arg0 >> 32 & 0xFF == 4)
        #expect(records[1].arg0 == Signposter.EndCode.nestedLoop)
        #expect(records[0].tNanos < records[1].tNanos)
    }

    @Test("launch.startup_task decodes as B then E with its arg0; launch.startup_complete is an instant")
    func startupTaskRecordsCarryTheirNumbers() throws {
        let log = RecordLog()
        let runtime = log.runtime()
        enable(runtime, .launch)
        let launch = signposter(.launch, runtime)
        launch.end(.launchStartupTask, launch.begin(.launchStartupTask, "name=Theme.apply priority=critical", arg0: 1))
        launch.event(.launchStartupComplete, "reason=failsafe", arg0: 8, arg1: 3)
        let records = log.records
        try #require(records.count == 3)
        #expect(records.map(\.phase) == [.begin, .end, .instant])
        // 74 is stall.render_starved, which took its id first; these two have 75 and 76.
        #expect(records.map(\.name) == [75, 75, 76])
        #expect(records[0].arg0 == 1)
        #expect(records[1].arg0 == Signposter.EndCode.ended)
        #expect(records[2].arg0 == 8 && records[2].arg1 == 3)
    }

    @Test("The overloads without numbers write code 0, which no given entrypoint or class writes")
    func missingNumbersAreZeroAndGivenOnesAreNot() throws {
        let log = RecordLog()
        let runtime = log.runtime()
        enable(runtime, .action, .stall)
        let action = signposter(.action, runtime)
        action.end(.actionGate, action.begin(.actionGate, message))
        action.end(.actionGate, action.begin(.actionGate, message, actionIndex: 0, entrypoint: 0))
        action.end(.actionGate, action.begin(.actionGate, message, actionIndex: 0, entrypoint: .max))
        let stall = signposter(.stall, runtime)
        stall.end(.stallMainTask, stall.begin(.stallMainTask, taskClass: "input", owner: "test"))
        stall.end(.stallMainTask, stall.begin(.stallMainTask, taskClass: "input", owner: "test", classID: 0, ownerID: 4))
        let begins = log.records.filter { $0.phase == .begin || $0.phase == .asyncBegin }
        try #require(begins.count == 5)
        #expect(begins.map { $0.arg0 >> 32 & 0xFF } == [0, 1, 255, 0, 1])
        #expect(begins[4].arg0 & 0xFFFF_FFFF == 4)
    }

    @Test("A flow hop is a flow record: out at the press's first hop, in after, with its hop code and age")
    func flowHopsAreFlowRecords() throws {
        let log = RecordLog()
        let runtime = log.runtime()
        enable(runtime, .key)
        let key = signposter(.key, runtime)
        key.flowHop(.appKeyDispatch, flow: 77, ageMicroseconds: 250)
        key.flowHop(.appIOWrite, flow: 77)
        key.flowHop(.appFrameCommit, flow: 77, ageMicroseconds: 9_000)
        let records = log.records
        try #require(records.count == 3)
        #expect(records.map(\.phase) == [.flowOut, .flowIn, .flowIn])
        #expect(records.allSatisfy { $0.name == SignpostName.keyFlow.rawValue && $0.arg1 == 77 })
        #expect(records.map { UInt8($0.arg0 & 0xFF) } == [1, 4, 11])
        #expect(records.map { Int64(bitPattern: $0.arg0) >> 8 } == [250, -1, 9_000])
    }

    @Test("Every key flow hop has a fixed, distinct, nonzero code, and only the dispatch starts a flow")
    func keyFlowHopCodes() {
        let codes = KeyFlowHop.allCases.map(\.traceCode)
        #expect(codes == Array(UInt8(1)...11))
        #expect(KeyFlowHop.allCases.filter(\.startsFlow) == [.appKeyDispatch])
    }

    @Test("action.commit is an async slice keyed by its signpost id; action.perform a thread slice")
    func actionIntervalsUseTheirRingPhases() throws {
        let runtime = TraceRuntime(role: .app)
        enable(runtime, .action)
        let action = signposter(.action, runtime)
        let first = action.begin(.actionCommit, message, actionIndex: 1, entrypoint: 0)
        let perform = action.begin(.actionPerform, message)
        let second = action.begin(.actionCommit, message, actionIndex: 2, entrypoint: 0)
        let firstID = try #require(asyncID(first))
        let secondID = try #require(asyncID(second))
        #expect(firstID != 0 && secondID != 0)
        #expect(firstID != secondID, "two overlapping action.commit intervals share an async id")
        #expect(perform.ring == .thread)
        #expect(first.beginUptimeNanos <= perform.beginUptimeNanos && perform.beginUptimeNanos <= second.beginUptimeNanos)
        action.end(.actionPerform, perform)
        action.end(.actionCommit, second, .committed)
        action.end(.actionCommit, first, .missed)
        #expect(records(runtime) == 6)
    }

    @Test("SignpostInterval keeps its begin time on the trace clock, traced or not")
    func intervalKeepsBeginTime() {
        let runtime = TraceRuntime(role: .app)
        let action = signposter(.action, runtime)
        let before = action.begin(.actionGate, message)
        enable(runtime, .action)
        let after = action.begin(.actionGate, message)
        #expect(before.beginUptimeNanos > 0)
        #expect(after.beginUptimeNanos >= before.beginUptimeNanos)
        action.end(.actionGate, before)
        action.end(.actionGate, after)
    }

    @Test("The begin time comes from the injected trace clock; the async id from the signpost id, not the time")
    func beginTimeFromTraceClock() throws {
        let runtime = TraceRuntime(role: .app)
        enable(runtime, .action)
        let clock = TraceClock(reader: .init(uptimeNanos: { 1_234 }, continuousNow: { ContinuousClock.now }))
        let action = Signposter(category: .action, mirror: mirror, trace: runtime, clock: clock)
        let first = action.begin(.actionCommit, message)
        let second = action.begin(.actionCommit, message)
        #expect(first.beginUptimeNanos == 1_234 && second.beginUptimeNanos == 1_234)
        let firstID = try #require(asyncID(first))
        let secondID = try #require(asyncID(second))
        #expect(firstID != secondID, "same-time action.commit intervals share an async id")
        action.end(.actionCommit, second, .committed)
        action.end(.actionCommit, first, .committed)
        #expect(records(runtime) == 4)
    }

    @Test("Names the catalog gives AB/AE are async slices; the synchronous spans are thread slices")
    func ringPhasePerName() {
        for name: SignpostName in [.actionCommit, .actionGate, .keyToFrame, .scrollToFrame, .motionRun, .switchWorkspace,
                                   .switchTab, .switchPaneFocus, .switchAppActivation, .createTab, .createWorkspace,
                                   .cefCreateBrowser, .launchProcessToMain, .launchFirstFrame, .daemonRequest] {
            #expect(!name.opensThreadSlice, "\(name)")
        }
        // A name that ends at a CommitBoundary ends after its turn's thread slices closed: never B/E.
        for name: SignpostName in [.actionCommit, .keyToFrame, .scrollToFrame, .switchAppActivation] {
            #expect(!name.opensThreadSlice, "\(name) ends at a CommitBoundary")
        }
        for name: SignpostName in [.actionPerform, .stallMainTask, .cefPump, .motionFrame, .stallCreateSurface, .taskRun,
                                   .ghosttyRender, .launchStartupTask, .cefMemoryPressureVote,
                                   .launchActionCatalogFirstMainAccess] {
            #expect(name.opensThreadSlice, "\(name)")
        }
    }

    @Test("The input age takes the top 24 bits, saturates, and reads all ones without an event")
    func inputAgeBits() {
        #expect(Signposter.inputAgeBits(milliseconds: -1) == 0xFF_FFFF << 40)
        #expect(Signposter.inputAgeBits(milliseconds: .nan) == 0xFF_FFFF << 40)
        #expect(Signposter.inputAgeBits(milliseconds: 2.5) == 2_500 << 40)
        #expect(Signposter.inputAgeBits(milliseconds: 0) == 0)
        #expect(Signposter.inputAgeBits(milliseconds: 60_000) == 0xFF_FFFE << 40)
        #expect(Signposter.inputAgeBits(milliseconds: 1e300) == 0xFF_FFFE << 40)
    }

    @Test("switch.app_activation's AB holds the notice code, the app activation bit and the notice's age")
    func appActivationBegin() throws {
        let log = RecordLog()
        let runtime = log.runtime()
        enable(runtime, .switch)
        let switching = signposter(.switch, runtime)
        let cmdTab = switching.beginAppActivation(noticeCode: 5, noticeName: "NSApplicationDidBecomeActiveNotification",
                                                  appActivation: true, noticeAgeMilliseconds: 2.5)
        switching.end(.switchAppActivation, cmdTab, .committed)
        let focusMove = switching.beginAppActivation(noticeCode: 2, noticeName: "NSWindowDidResignKeyNotification",
                                                     appActivation: false, noticeAgeMilliseconds: 0)
        switching.end(.switchAppActivation, focusMove, .missed)
        let records = log.records
        try #require(records.map(\.phase) == [.asyncBegin, .asyncEnd, .asyncBegin, .asyncEnd])
        #expect(records.allSatisfy { $0.name == SignpostName.switchAppActivation.rawValue })
        #expect(records[0].arg0 == 5 | 1 << 8 | 2_500 << 40)
        #expect(records[1].arg0 == 0, "committed")
        #expect(records[2].arg0 == 2, "no app activation bit, no age")
        #expect(records[3].arg0 == 1, "missed")
    }

    @Test("Scroll phases and targets have fixed, distinct, nonzero ring codes")
    func scrollCodes() {
        let phases = ScrollFramePhase.allCases.map(\.traceCode)
        #expect(phases == [1, 2, 3, 4, 5, 6])
        #expect(ScrollFrameTarget.layout.traceCode == 1 && ScrollFrameTarget.content.traceCode == 2)
    }

    @Test("A disabled signpost subsystem still gets a usable async id from the begin time")
    func asyncIDFallsBackToBeginTime() {
        #expect(Signposter.asyncID(.null, beginNanos: 77) == 77)
        #expect(Signposter.asyncID(.invalid, beginNanos: 78) == 78)
    }
}
