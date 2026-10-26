import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFocus
import CmuxNextSignposts
@testable import CmuxNextTrace
import QuartzCore
import Testing

/// `switch.pane_focus` (p09-observability 029): every pane focus move is one ``Signposter`` interval in
/// every build, recording or not. A focus intent's drain begins its ring async pair and the
/// `CommitBoundary` after the turn that settled focus on the new pane ends it; drains that are not an
/// intent (topology reports, programmatic moves) write nothing.
@MainActor @Suite(.serialized)
struct PaneFocusTimingTests {
    /// A coordinator with two panes, focus on `left`, timed into a runtime with only the `switch` category on.
    private func coordinator() -> (FocusCoordinator, SwitchFrameTimer, PaneFocusRecordLog) {
        let log = PaneFocusRecordLog()
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.switch.traceBit))
        let timer = SwitchFrameTimer(owner: "test.pane_focus", signpost: .switchPaneFocus, trace: runtime)
        let focus = FocusCoordinator()
        focus.paneFocusTimer = timer
        focus.send(.topology(FocusTopology(workspace: "pane-focus-workspace", panes: [
            .init(id: "left", tabs: [.init(id: "left-tab", kind: .terminal)], selected: "left-tab"),
            .init(id: "right", tabs: [.init(id: "right-tab", kind: .terminal)], selected: "right-tab"),
        ])))
        focus.send(.focusPane("left", source: .programmatic))
        pollingTurn()
        return (focus, timer, log)
    }

    /// Runs one main run-loop turn that polls and exits without waiting: its exit fires the boundary
    /// (a far-future timer keeps the mode non-empty, so the loop runs its observers).
    private func pollingTurn() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, true)
        CFRunLoopTimerInvalidate(timer)
    }

    @Test func aKeyMoveIsOneAsyncPairEndedAtItsCommitBoundaryWhileNotRecording() {
        let (focus, timer, log) = coordinator()
        #expect(log.records.isEmpty, "the topology report and a programmatic move are not intents")
        #expect(!timer.isRecording)
        focus.send(.focusPane("right", source: .keyboard))
        #expect(focus.state.pane == "right")
        #expect(log.phases == [.asyncBegin], "the intent writes the AB; the AE waits for the turn's boundary")
        pollingTurn()
        #expect(log.phases == [.asyncBegin, .asyncEnd])
        #expect(log.records.allSatisfy { $0.name == SignpostName.switchPaneFocus.rawValue })
        #expect(log.records.last?.arg0 == 0, "a committed boundary ends it as committed")
        #expect(log.records.first?.arg1 == log.records.last?.arg1, "one async id pairs the AB and the AE")
    }

    @Test func drainsThatAreNotAnIntentWriteNothing() {
        let (focus, _, log) = coordinator()
        focus.send(.focusPane("right", source: .programmatic))
        focus.send(.responder(.content(pane: "left"), source: .programmatic))
        focus.send(.windowKey(true))
        pollingTurn()
        #expect(log.records.isEmpty, "programmatic moves and reports are not pane focus intents: \(log.phases)")
    }

    @Test func anIntentAtTheFocusedPaneWritesNothing() {
        let (focus, _, log) = coordinator()
        focus.send(.focusPane("left", source: .mouse))
        pollingTurn()
        #expect(log.records.isEmpty)
    }

    @Test func anIntentThatKeepsThePaneEndsAsMissed() {
        let (focus, _, log) = coordinator()
        focus.send(.focusPane("no-such-pane", source: .keyboard))
        #expect(focus.state.pane == "left")
        #expect(log.phases == [.asyncBegin, .asyncEnd], "the drain that kept the pane ends its pair")
        #expect(log.records.last?.arg0 == 1, "a move that did not land ends as a missed commit, so readers drop it")
        pollingTurn()
        #expect(log.records.count == 2, "the boundary does not end it twice")
    }

    /// A pane-navigation key begins the move before it sends its event (PaneHandlers.focusByKey): the drain
    /// keeps that begin, so the interval covers the key's own work too.
    @Test func anExplicitBeginIsKeptThroughTheDrainItsEventStarts() {
        let (focus, _, log) = coordinator()
        DebugPaneFocus.began(focus)
        focus.send(.focusPane("right", source: .keyboard))
        #expect(log.phases == [.asyncBegin], "the drain did not supersede the key's begin")
        pollingTurn()
        #expect(log.phases == [.asyncBegin, .asyncEnd])
        #expect(log.records.last?.arg0 == 0)
    }

    @Test func theKeyBeingHandledIsTheInputAge() throws {
        let (focus, _, log) = coordinator()
        // KeyRouter runs a key's binding in this scope (a synthetic key never becomes `NSApp.currentEvent`).
        DebugTabSwitch.handling(input: CACurrentMediaTime() - 0.003) { focus.send(.focusPane("right", source: .keyboard)) }
        focus.send(.focusPane("left", source: .keyboard))
        let ages = log.records.filter { $0.phase == .asyncBegin }.map(\.arg0)
        try #require(ages.count == 2)
        #expect(ages[0] >= 3_000 && ages[0] < 1_000_000, "a key 3 ms old: \(ages[0]) µs")
        #expect(ages[1] == .max, "no input event: all ones")
    }

    @Test func onlyUserEventsAimedAtAnotherPaneAreIntents() {
        typealias Timing = DebugPaneFocus
        #expect(Timing.aimsAtAnotherPane(.focusPane("b", source: .cli), from: "a"))
        #expect(Timing.aimsAtAnotherPane(.selectTab(pane: "b", tab: "t", source: .palette), from: "a"))
        #expect(Timing.aimsAtAnotherPane(.responder(.addressBar(pane: "b"), source: .mouse), from: "a"))
        #expect(Timing.aimsAtAnotherPane(.focusPane("b", source: .keyboard), from: nil))
        #expect(!Timing.aimsAtAnotherPane(.focusPane("a", source: .keyboard), from: "a"))
        #expect(!Timing.aimsAtAnotherPane(.focusPane("b", source: .programmatic), from: "a"))
        #expect(!Timing.aimsAtAnotherPane(.responder(.sidebar, source: .mouse), from: "a"))
        #expect(!Timing.aimsAtAnotherPane(.focusTarget(.addressBar, source: .keyboard), from: "a"))
        #expect(!Timing.aimsAtAnotherPane(.appActive(true), from: "a"))
    }
}

/// The records a test runtime's stub writes, in order.
private final class PaneFocusRecordLog: Sendable {
    private let state = Mutex<[TraceRuntime.StubRecord]>([])

    func append(_ record: TraceRuntime.StubRecord) { state.withLock { $0.append(record) } }

    var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

    var phases: [TraceRuntime.Phase] { records.map(\.phase) }
}
