import CmuxNextFocus
import Testing

/// The person-intent target (``FocusState/personTarget``, cmux-ad m12 on #35275): the focus machine sets it to the typing
/// target on each focus move the person makes (mouse, keyboard, palette) and never on a script's, the CLI's or the app's.
/// A creation hold's keys go to their press-time terminal at the reply bound only while it did not change.
struct FocusPersonTargetTests {
    /// Two terminal panes, `a` focused by the app (a restore): no move of the person's yet.
    private func twoTerminals() -> (FocusMachine, FocusState) {
        let machine = FocusMachine()
        var state = FocusState()
        let a = FocusTopology.Pane(id: "a", tabs: [.init(id: "a-tab", kind: .terminal)], selected: "a-tab")
        let b = FocusTopology.Pane(id: "b", tabs: [.init(id: "b-tab", kind: .terminal)], selected: "b-tab")
        _ = machine.send(.topology(FocusTopology(workspace: "w", panes: [a, b])), into: &state)
        _ = machine.send(.focusPane("a", source: .programmatic), into: &state)
        return (machine, state)
    }

    @Test(arguments: [FocusEvent.Source.mouse, .keyboard, .palette])
    func thePersonsOwnMoveSetsTheirTarget(_ source: FocusEvent.Source) {
        let (machine, initial) = twoTerminals()
        var state = initial
        #expect(state.typingTab == "a-tab" && state.personTarget == nil)
        _ = machine.send(.focusPane("b", source: source), into: &state)
        #expect(state.typingTab == "b-tab")
        #expect(state.personTarget == "b-tab", "a \(source) move did not set the person's target")
    }

    /// A click in another pane's view reaches the machine as the window's responder report with the mouse source (no focus
    /// event of the person's: `ShellWindow.reportResponder` inside the mouse-down's dispatch): it sets the person's target
    /// too (round 8 of #35275: the pane-click row typed the held line into the terminal the person left).
    @Test func aClickInAnotherPanesViewSetsThePersonsTarget() {
        let (machine, initial) = twoTerminals()
        var state = initial
        _ = machine.send(.responder(.content(pane: "b"), source: .mouse), into: &state)
        #expect(state.typingTab == "b-tab")
        #expect(state.personTarget == "b-tab", "the mouse responder report did not set the person's target")
    }

    /// A responder report inside a key's dispatch is no focus choice of the person's (lead on #35275): after a script moved
    /// the focus, a key the person types (a responder change it causes) must not copy the script's target into theirs, or
    /// the bound drops the keys they typed for the press-time terminal.
    @Test func aKeysResponderReportLeavesThePersonsTarget() {
        let (machine, initial) = twoTerminals()
        var state = initial
        _ = machine.send(.focusPane("a", source: .mouse), into: &state)
        _ = machine.send(.focusPane("b", source: .cli), into: &state)
        _ = machine.send(.responder(.content(pane: "b"), source: .keyboard), into: &state)
        #expect(state.typingTab == "b-tab")
        #expect(state.personTarget == "a-tab", "a key's responder report set the person's target to \(state.personTarget ?? "none")")
    }

    @Test(arguments: [FocusEvent.Source.cli, .programmatic])
    func aScriptsOrTheAppsMoveLeavesThePersonsTarget(_ source: FocusEvent.Source) {
        let (machine, initial) = twoTerminals()
        var state = initial
        _ = machine.send(.focusPane("a", source: .mouse), into: &state)
        #expect(state.personTarget == "a-tab")
        _ = machine.send(.focusPane("b", source: source), into: &state)
        #expect(state.typingTab == "b-tab")
        #expect(state.personTarget == "a-tab", "a \(source) move changed the person's target to \(state.personTarget ?? "none")")
    }
}
