import CmuxNextFocus
import CmuxNextInputModel
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextInvariants
#endif
import Testing
@testable import CmuxNextApp

/// Something takes the keys (plans/cmux-next/focus-invariant.md, felt 1f): W10 reports a state where a key
/// the person types goes nowhere, and W11 a focus target that never lands; neither reports the named exceptions.
struct KeysHaveTargetInvariantTests {
    private func window(_ resolved: FocusState.Resolved, isKey: Bool, visible: Bool = true,
                        panes: [FocusTopology.Pane] = [FocusTopology.Pane(id: "pane_a", tabs: [FocusTopology.Tab(id: "tab_t", kind: .terminal)], selected: "tab_t")],
                        expectation: FocusState.Expectation? = nil) -> InputObservation.Window {
        var model = FocusState()
        model.resolved = resolved
        model.underlying = resolved
        model.windowKey = isKey
        model.topology = FocusTopology(workspace: "ws", panes: panes, screens: [])
        model.expectation = expectation
        return InputObservation.Window(id: "window_1", model: model, responder: .content(pane: "pane_a"), isKey: isKey,
                                       ghosttyFocused: [], presented: ["pane_a": "tab_t"], visible: visible)
    }

    private func w10(_ observation: InputObservation) -> [InputViolation] {
        InputInvariants.keysHaveTarget(observation)
    }

    @Test func anActiveAppWithAShownWindowAndNoKeyWindowIsW10() {
        let observation = InputObservation(windows: [window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: false)], keyWindow: .none,
                                           paletteOpen: false, activeWindow: "window_1", context: FocusState.Context(), appActive: true)
        #expect(w10(observation).map(\.invariant) == [.keysHaveTarget])
    }

    @Test func anInactiveAppHasNoKeyWindowByDesign() {
        let observation = InputObservation(windows: [window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: false)], keyWindow: .none,
                                           paletteOpen: false, activeWindow: "window_1", context: FocusState.Context(), appActive: false)
        #expect(w10(observation).isEmpty)
    }

    @Test func anActiveAppWithOnlyHiddenWindowsIsTheNoWindowException() {
        let observation = InputObservation(windows: [window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: false, visible: false)],
                                           keyWindow: .none, paletteOpen: false, activeWindow: "window_1",
                                           context: FocusState.Context(), appActive: true)
        #expect(w10(observation).isEmpty)
    }

    @Test func aKeyWindowWhoseModelTargetsNothingIsW10() {
        let observation = InputObservation(windows: [window(.none, isKey: true)], keyWindow: .window("window_1"),
                                           paletteOpen: false, activeWindow: "window_1", context: FocusState.Context(), appActive: true)
        #expect(w10(observation).map(\.invariant) == [.keysHaveTarget])
    }

    @Test func anEmptyWorkspaceIsTheEmptyStateException() {
        let observation = InputObservation(windows: [window(.none, isKey: true, panes: [])], keyWindow: .window("window_1"),
                                           paletteOpen: false, activeWindow: "window_1", context: FocusState.Context(), appActive: true)
        #expect(w10(observation).isEmpty)
    }

    @Test func aKeyWindowFocusedOnATabLessPaneBesideOneWithTabsIsW10() {
        let panes = [FocusTopology.Pane(id: "pane_a", tabs: [], selected: nil),
                     FocusTopology.Pane(id: "pane_b", tabs: [FocusTopology.Tab(id: "tab_t", kind: .terminal)], selected: "tab_t")]
        let observation = InputObservation(windows: [window(.emptyPane(pane: "pane_a"), isKey: true, panes: panes)],
                                           keyWindow: .window("window_1"), paletteOpen: false, activeWindow: "window_1",
                                           context: FocusState.Context(), appActive: true)
        #expect(w10(observation).map(\.invariant) == [.keysHaveTarget])
    }

    @Test func aKeyWindowOnItsTerminalIsInSync() {
        let observation = InputObservation(windows: [window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: true)],
                                           keyWindow: .window("window_1"), paletteOpen: false, activeWindow: "window_1",
                                           context: FocusState.Context(), appActive: true)
        #expect(w10(observation).isEmpty)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    // W11 runs as the invariant registry runs it in the app (InputVerificationService.expectationRule): one turn per
    // step, at the step's time.

    @MainActor @Test func anExpectationReKeyedFromItsSurfaceToItsTabKeepsItsClock() {
        let run = W11Run()
        let start = run.now
        let bySurface = FocusState.Expectation(key: .surface("7"), target: .content, generation: 5)
        let byTab = FocusState.Expectation(key: .tab("tab_7"), target: .content, generation: 5)
        #expect(run.step(at: start, [window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: true, expectation: bySurface)]).isEmpty)
        let later = run.step(at: start + run.limit, [window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: true, expectation: byTab)])
        #expect(later == ["W11"])
    }

    @MainActor @Test func aWindowWhoseKeysWaitForACreatesReplyStartsItsClockWhenTheHoldEnds() {
        let run = W11Run()
        let start = run.now
        let pending = [window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: true,
                              expectation: FocusState.Expectation(key: .tab("tab_new"), target: .addressBar, generation: 3))]
        #expect(run.step(at: start, pending, holding: ["window_1"]).isEmpty)
        // The slow daemon held the keys 5 s: no W11 while it held them, none at once after.
        #expect(run.step(at: start + .seconds(5), pending, holding: ["window_1"]).isEmpty)
        #expect(run.step(at: start + .seconds(5) + .milliseconds(1), pending).isEmpty)
        #expect(run.step(at: start + .seconds(5) + run.limit, pending) == ["W11"])
    }

    @MainActor @Test func anExpectationPendingPastTheCreationHoldIsW11AndANewerOneStartsItsOwnClock() {
        let run = W11Run()
        let start = run.now
        let first = FocusState.Expectation(key: .tab("tab_new"), target: .addressBar, generation: 3)
        let pending = [window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: true, expectation: first)]
        #expect(run.step(at: start, pending).isEmpty)
        #expect(run.scheduled == run.limit, "one deadline at the limit, so no input need come to report it")
        #expect(run.step(at: start + run.limit - .milliseconds(1), pending).isEmpty)
        #expect(run.step(at: start + run.limit, pending) == ["W11"])
        // A newer intent's expectation starts over: no report, and its own deadline.
        let second = FocusState.Expectation(key: .tab("tab_other"), target: .content, generation: 4)
        let newer = [window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: true, expectation: second)]
        run.scheduled = nil
        #expect(run.step(at: start + run.limit + .seconds(1), newer).isEmpty)
        #expect(run.scheduled == run.limit)
        // Landed: nothing pending, nothing to wait for.
        run.scheduled = nil
        #expect(run.step(at: start + run.limit + .seconds(1), [window(.addressBar(pane: "pane_a", tab: "tab_other"), isKey: true)]).isEmpty)
        #expect(run.scheduled == nil)
        // At its old limit nothing is reported: the wait ended.
        #expect(run.step(at: start + run.limit * 3, [window(.addressBar(pane: "pane_a", tab: "tab_other"), isKey: true)]).isEmpty)
    }
    #endif
}

#if DEBUG || CMUX_BENCH_HOOKS
/// W11 in a registry of its own, with a clock and a deadline the test moves.
@MainActor
private final class W11Run {
    let limit = InputVerificationService.expectationLimit
    var now = ContinuousClock.now
    var windows: [InputObservation.Window] = []
    var holding: Set<String> = []
    /// The delay of the liveness deadline the registry asked for last.
    var scheduled: Duration?
    private var registry: InvariantRegistry?

    init() {
        let registry = InvariantRegistry(mode: .on, now: { [unowned self] in now }, schedule: { [unowned self] delay, _ in scheduled = delay })
        registry.declare(InputVerificationService.expectationRule { [unowned self] _ in (windows, holding) })
        self.registry = registry
    }

    /// One turn at `time` with `windows`: the ids it reported.
    func step(at time: ContinuousClock.Instant, _ windows: [InputObservation.Window], holding: Set<String> = []) -> [InvariantID] {
        guard let registry else { return [] }
        (now, self.windows, self.holding) = (time, windows, holding)
        let before = registry.ledger.lastSeq
        registry.touch(.focus, .window("window_1"))
        registry.runTurn()
        return registry.ledger.since(before).violations.map(\.id)
    }
}
#endif
