import CmuxNextFocus
import Testing

/// The count of the person's focus choices (``FocusState/personMoveSeq``, cmux-ad m12 on #35275): the focus machine counts
/// each focus move the person makes (mouse, keyboard, palette) and each responder report of their click, and never a
/// script's, the CLI's or the app's move, nor a responder change inside a key's dispatch. A creation hold's keys go to their
/// press-time terminal at the reply bound only while it did not change.
struct FocusPersonMovesTests {
    /// Two terminal panes, `a` focused by the app (a restore): no choice of the person's yet.
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
    func thePersonsOwnMoveCounts(_ source: FocusEvent.Source) {
        let (machine, initial) = twoTerminals()
        var state = initial
        #expect(state.typingTab == "a-tab" && state.personMoveSeq == 0)
        _ = machine.send(.focusPane("b", source: source), into: &state)
        #expect(state.typingTab == "b-tab")
        #expect(state.personMoveSeq == 1, "a \(source) move did not count")
    }

    /// A click in another pane's view reaches the machine as the window's responder report with the mouse source (no focus
    /// event of the person's: `ShellWindow.reportResponder` inside the mouse-down's dispatch): it counts too (round 8 of
    /// #35275: the pane-click row typed the held line into the terminal the person left).
    @Test func aClickInAnotherPanesViewCounts() {
        let (machine, initial) = twoTerminals()
        var state = initial
        _ = machine.send(.responder(.content(pane: "b"), source: .mouse), into: &state)
        #expect(state.typingTab == "b-tab")
        #expect(state.personMoveSeq == 1, "the mouse responder report did not count")
    }

    /// A move that ends where the person was before (back onto the same terminal, or onto no terminal again) counts as
    /// much as any other (review of #35275 at 455dd11fe51a: a value compare took it for no move).
    @Test func aMoveBackToTheSameTargetCounts() {
        let (machine, initial) = twoTerminals()
        var state = initial
        _ = machine.send(.focusPane("b", source: .mouse), into: &state)
        _ = machine.send(.focusPane("a", source: .cli), into: &state)
        let atPress = state.personMoveSeq
        _ = machine.send(.focusPane("b", source: .mouse), into: &state)
        #expect(state.typingTab == "b-tab")
        #expect(state.personMoveSeq == atPress + 1, "a click back onto the person's previous pane did not count")
        _ = machine.send(.responder(.textField, source: .mouse), into: &state)
        #expect(state.typingTab == nil)
        #expect(state.personMoveSeq == atPress + 2, "a click into a text field did not count")
    }

    /// A responder report inside a key's dispatch is no focus choice of the person's (lead on #35275): after a script moved
    /// the focus, a key the person types (a responder change it causes) must not count, or the bound drops the keys they
    /// typed for the press-time terminal.
    @Test func aKeysResponderReportDoesNotCount() {
        let (machine, initial) = twoTerminals()
        var state = initial
        _ = machine.send(.focusPane("a", source: .mouse), into: &state)
        _ = machine.send(.focusPane("b", source: .cli), into: &state)
        _ = machine.send(.responder(.content(pane: "b"), source: .keyboard), into: &state)
        #expect(state.typingTab == "b-tab")
        #expect(state.personMoveSeq == 1, "a key's responder report counted: \(state.personMoveSeq)")
    }

    @Test(arguments: [FocusEvent.Source.cli, .programmatic])
    func aScriptsOrTheAppsMoveDoesNotCount(_ source: FocusEvent.Source) {
        let (machine, initial) = twoTerminals()
        var state = initial
        _ = machine.send(.focusPane("a", source: .mouse), into: &state)
        #expect(state.personMoveSeq == 1)
        _ = machine.send(.focusPane("b", source: source), into: &state)
        _ = machine.send(.selectTab(pane: "a", tab: "a-tab", source: source), into: &state)
        #expect(state.personMoveSeq == 1, "a \(source) move counted: \(state.personMoveSeq)")
    }

    /// Inside a run the person chose from a menu (``FocusMachine/send(_:into:menuPick:)``) a focus choice counts whatever
    /// source it carries (AppKit runs a chosen item's action outside any input event's dispatch, so its events carry the
    /// CLI's or the app's source), except a responder report a key's dispatch made: a held key run again inside the run's
    /// task is no focus choice of the person's (round 10 of #35275; review of #35874, finding 2).
    @Test func aMenuPicksChoicesCountButAKeysResponderReportDoesNot() {
        let (machine, initial) = twoTerminals()
        var state = initial
        _ = machine.send(.responder(.textField, source: .programmatic), into: &state)
        #expect(state.personMoveSeq == 0, "an app responder report counted outside a menu pick")
        _ = machine.send(.responder(.textField, source: .programmatic), into: &state, menuPick: true)
        #expect(state.personMoveSeq == 1, "a responder report of a menu pick did not count")
        _ = machine.send(.focusPane("b", source: .cli), into: &state, menuPick: true)
        #expect(state.personMoveSeq == 2, "a focus move of a menu pick did not count")
        _ = machine.send(.responder(.content(pane: "a"), source: .keyboard), into: &state, menuPick: true)
        #expect(state.personMoveSeq == 2, "a key's responder report inside a menu pick counted as the person's choice")
    }
}
