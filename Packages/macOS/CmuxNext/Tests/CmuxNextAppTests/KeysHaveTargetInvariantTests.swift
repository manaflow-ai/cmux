import CmuxNextFocus
import CmuxNextInputModel
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

    @Test func anExpectationReKeyedFromItsSurfaceToItsTabKeepsItsClock() {
        let start = ContinuousClock.now
        let limit = InputInvariantMonitor.expectationLimit
        let bySurface = FocusState.Expectation(key: .surface("7"), target: .content, generation: 5)
        let byTab = FocusState.Expectation(key: .tab("tab_7"), target: .content, generation: 5)
        var ages = FocusExpectationAges()
        _ = ages.check([window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: true, expectation: bySurface)], now: start, limit: limit)
        let later = ages.check([window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: true, expectation: byTab)], now: start + limit, limit: limit)
        #expect(later.violations.map(\.invariant) == [.expectationLands])
    }

    @Test func aWindowWhoseKeysWaitForACreatesReplyStartsItsClockWhenTheHoldEnds() {
        let start = ContinuousClock.now
        let limit = InputInvariantMonitor.expectationLimit
        let pending = [window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: true,
                              expectation: FocusState.Expectation(key: .tab("tab_new"), target: .addressBar, generation: 3))]
        var ages = FocusExpectationAges()
        _ = ages.check(pending, now: start, limit: limit, holding: ["window_1"])
        // The slow daemon held the keys 5 s: no W11 while it held them, none at once after.
        #expect(ages.check(pending, now: start + .seconds(5), limit: limit, holding: ["window_1"]).violations.isEmpty)
        #expect(ages.check(pending, now: start + .seconds(5) + .milliseconds(1), limit: limit).violations.isEmpty)
        #expect(ages.check(pending, now: start + .seconds(5) + limit, limit: limit).violations.map(\.invariant) == [.expectationLands])
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

    @Test func anExpectationPendingPastTheCreationHoldIsW11AndANewerOneStartsItsOwnClock() {
        let start = ContinuousClock.now
        let limit = InputInvariantMonitor.expectationLimit
        let first = FocusState.Expectation(key: .tab("tab_new"), target: .addressBar, generation: 3)
        let pending = [window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: true, expectation: first)]
        var ages = FocusExpectationAges()
        #expect(ages.check(pending, now: start, limit: limit).violations.isEmpty)
        #expect(ages.check(pending, now: start + limit - .milliseconds(1), limit: limit).violations.isEmpty)
        #expect(ages.check(pending, now: start + limit, limit: limit).violations.map(\.invariant) == [.expectationLands])
        // A newer intent's expectation starts over.
        let second = FocusState.Expectation(key: .tab("tab_other"), target: .content, generation: 4)
        let newer = [window(.terminal(pane: "pane_a", tab: "tab_t"), isKey: true, expectation: second)]
        let later = start + limit + .seconds(1)
        let result = ages.check(newer, now: later, limit: limit)
        #expect(result.violations.isEmpty)
        #expect(result.oldest == later)
        // Landed: nothing pending, nothing to re-check.
        #expect(ages.check([window(.addressBar(pane: "pane_a", tab: "tab_other"), isKey: true)], now: later, limit: limit).oldest == nil)
    }
}
