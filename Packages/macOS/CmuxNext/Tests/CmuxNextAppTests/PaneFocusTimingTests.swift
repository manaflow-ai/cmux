import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextSignposts
@testable import CmuxNextTrace
import QuartzCore
import Testing

/// `switch.pane_focus` (p09-observability 029): every pane focus move is one ``Signposter`` interval in
/// every build, recording or not. A focus intent's drain begins its ring async pair and the
/// `CommitBoundary` after the turn that settled focus on the new pane ends it; drains that are not an
/// intent (topology reports, programmatic moves, moves in a hidden workspace) write nothing.
@MainActor @Suite(.serialized)
struct PaneFocusTimingTests {
    private static let workspace = "pane-focus-workspace"

    /// A timer on its own runtime with only the `switch` category on, and the log of what it writes.
    private func makeTimer() -> (SwitchFrameTimer, PaneFocusRecordLog) {
        let log = PaneFocusRecordLog()
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.switch.traceBit))
        return (SwitchFrameTimer(owner: "test.pane_focus", signpost: .switchPaneFocus, trace: runtime), log)
    }

    /// Shows two panes in `focus`, with focus on `left`, and lets the turn end.
    private func showTwoPanes(_ focus: FocusCoordinator) {
        focus.send(.topology(FocusTopology(workspace: Self.workspace, panes: [
            .init(id: "left", tabs: [.init(id: "left-tab", kind: .terminal)], selected: "left-tab"),
            .init(id: "right", tabs: [.init(id: "right-tab", kind: .terminal)], selected: "right-tab"),
        ])))
        focus.send(.focusPane("left", source: .programmatic))
        pollingTurn()
    }

    /// A coordinator with two panes, focus on `left`, timed into its own runtime.
    private func coordinator() -> (FocusCoordinator, SwitchFrameTimer, PaneFocusRecordLog) {
        let (timer, log) = makeTimer()
        let focus = FocusCoordinator()
        focus.paneFocusTimer = timer
        showTwoPanes(focus)
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

    /// A move in a workspace the window does not show only remembers that workspace's pane: focus stays,
    /// so it is no move here and writes no missed pair.
    @Test func anIntentForAHiddenWorkspaceWritesNothing() {
        let (focus, _, log) = coordinator()
        focus.send(.focusPane("right", workspace: "hidden", source: .keyboard))
        focus.send(.selectTab(pane: "right", tab: "right-tab", workspace: "hidden", source: .mouse))
        pollingTurn()
        #expect(focus.state.pane == "left")
        #expect(log.records.isEmpty, "a hidden workspace's move wrote \(log.phases)")
    }

    @Test func anIntentNamingTheShownWorkspaceIsAMove() {
        let (focus, _, log) = coordinator()
        focus.send(.focusPane("right", workspace: Self.workspace, source: .keyboard))
        #expect(focus.state.pane == "right")
        pollingTurn()
        #expect(log.phases == [.asyncBegin, .asyncEnd])
        #expect(log.records.last?.arg0 == 0)
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
        let keyInput = KeyInputScope()
        focus.keyInput = keyInput
        keyInput.handling(input: CACurrentMediaTime() - 0.003) { focus.send(.focusPane("right", source: .keyboard)) }
        focus.send(.focusPane("left", source: .keyboard))
        let ages = log.records.filter { $0.phase == .asyncBegin }.map(\.arg0)
        try #require(ages.count == 2)
        #expect(ages[0] >= 3_000 && ages[0] < 1_000_000, "a key 3 ms old: \(ages[0]) µs")
        #expect(ages[1] == .max, "no input event: all ones")
    }

    /// A click's move takes the age of the click being dispatched (`InputDispatchContext`, the action run's input),
    /// not `NSApp.currentEvent`: once the dispatch ends, a move (a socket `pane.focus`) has no input age.
    @Test func theClickBeingDispatchedIsTheInputAge() throws {
        _ = NSApplication.shared
        let (focus, _, log) = coordinator()
        let dispatch = InputDispatchContext()
        focus.inputDispatch = dispatch
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: CACurrentMediaTime() - 0.003, windowNumber: 0, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        dispatch.dispatching(click) { focus.send(.focusPane("right", source: .mouse)) }
        focus.send(.focusPane("left", source: .mouse))
        let ages = log.records.filter { $0.phase == .asyncBegin }.map(\.arg0)
        try #require(ages.count == 2)
        #expect(ages[0] >= 3_000 && ages[0] < 1_000_000, "the click 3 ms old: \(ages[0]) µs (all ones: no input stage)")
        #expect(ages[1] == .max, "no event being dispatched: all ones")
    }

    /// A bare key the key router runs (a page that owns bare keys, KeyRouter+BareKeys) carries its own age into
    /// the move its binding makes: the router runs the binding inside its key-input scope, which the window's
    /// coordinator reads. Without that scope the begin's arg0 is all ones.
    @Test func aBareKeyThroughTheRouterCarriesItsAge() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: [Self.workspace]))
        defer { for open in services.windows.controllers { open.window?.close() } }
        let window = try #require(controller.window)
        let (timer, log) = makeTimer()
        controller.focus.paneFocusTimer = timer
        showTwoPanes(controller.focus)
        try #require(controller.focus.state.pane == "left")
        // The diff viewer's bare `j` (Diff: Next Line), bound here to a pane focus move from the keyboard.
        services.registry.bind("diffViewerNextLine", invoke: { _ in controller.focus.send(.focusPane("right", source: .keyboard)) })
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: CACurrentMediaTime() - 0.003,
                                                windowNumber: window.windowNumber, context: nil, characters: "j",
                                                charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        #expect(services.keyRouter.dispatchBare(key, in: window, controller: controller, context: KeyContext(bits: [.diffViewerFocused]),
                                                facts: KeyRouter.Facts()))
        #expect(controller.focus.state.pane == "right")
        let ages = log.records.filter { $0.phase == .asyncBegin }.map(\.arg0)
        try #require(ages.count == 1, "the key's move wrote \(log.phases)")
        #expect(ages[0] >= 3_000 && ages[0] < 1_000_000, "the bare key 3 ms old: \(ages[0]) µs (all ones: no input stage)")
    }

    @Test func onlyUserEventsAimedAtAnotherPaneOfTheShownWorkspaceAreIntents() {
        typealias Timing = DebugPaneFocus
        var onA = FocusState()
        onA.topology = FocusTopology(workspace: "shown")
        onA.pane = "a"
        var none = onA
        none.pane = nil
        #expect(Timing.aimsAtAnotherPane(.focusPane("b", source: .cli), in: onA))
        #expect(Timing.aimsAtAnotherPane(.selectTab(pane: "b", tab: "t", source: .palette), in: onA))
        #expect(Timing.aimsAtAnotherPane(.responder(.addressBar(pane: "b"), source: .mouse), in: onA))
        #expect(Timing.aimsAtAnotherPane(.focusPane("b", source: .keyboard), in: none))
        #expect(Timing.aimsAtAnotherPane(.focusPane("b", workspace: "shown", source: .keyboard), in: onA))
        #expect(Timing.aimsAtAnotherPane(.selectTab(pane: "b", tab: "t", workspace: "shown", source: .mouse), in: onA))
        #expect(!Timing.aimsAtAnotherPane(.focusPane("b", workspace: "hidden", source: .keyboard), in: onA))
        #expect(!Timing.aimsAtAnotherPane(.selectTab(pane: "b", tab: "t", workspace: "hidden", source: .mouse), in: onA))
        #expect(!Timing.aimsAtAnotherPane(.focusPane("a", source: .keyboard), in: onA))
        #expect(!Timing.aimsAtAnotherPane(.focusPane("b", source: .programmatic), in: onA))
        #expect(!Timing.aimsAtAnotherPane(.responder(.sidebar, source: .mouse), in: onA))
        #expect(!Timing.aimsAtAnotherPane(.focusTarget(.addressBar, source: .keyboard), in: onA))
        #expect(!Timing.aimsAtAnotherPane(.appActive(true), in: onA))
    }
}

/// The records a test runtime's stub writes, in order.
private nonisolated final class PaneFocusRecordLog: Sendable {
    private let state = Mutex<[TraceRuntime.StubRecord]>([])

    func append(_ record: TraceRuntime.StubRecord) { state.withLock { $0.append(record) } }

    var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

    var phases: [TraceRuntime.Phase] { records.map(\.phase) }
}
