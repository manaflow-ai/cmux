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
