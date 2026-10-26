@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import os
import Testing

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

    /// Runs every public emit method once: 9 intervals (18 records) and 3 events.
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
        key.flowHop("app.key.dispatch", flow: 42, ageMicroseconds: 120)
        let stall = signposter(.stall, runtime)
        stall.end(.stallMainTask, stall.begin(.stallMainTask, taskClass: "visible", owner: "test", classID: 2, ownerID: 9))
        stall.event(.stallOverBudget, "class=visible")
        stall.event(.stallOverBudget, "class=visible", arg0: 7, arg1: 8)
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
        enable(runtime, .action, .key, .stall)
        emitEverything(runtime)
        #expect(records(runtime) == 9 * 2 + 3)
    }

    @Test("A name records only under its own category's flag")
    func flagIsPerCategory() {
        let runtime = TraceRuntime(role: .app)
        enable(runtime, .key)
        let action = signposter(.action, runtime)
        action.end(.actionPerform, action.begin(.actionPerform, message))
        #expect(records(runtime) == 0)
        signposter(.key, runtime).flowHop("app.io_write", flow: 1)
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
                                   .switchTab, .switchPaneFocus, .createTab, .createWorkspace, .cefCreateBrowser,
                                   .launchProcessToMain, .launchFirstFrame, .daemonRequest] {
            #expect(!name.opensThreadSlice, "\(name)")
        }
        for name: SignpostName in [.actionPerform, .stallMainTask, .cefPump, .motionFrame, .stallCreateSurface, .taskRun,
                                   .ghosttyRender] {
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
