import CmuxNextFocus
import Testing

/// P0 INVERSE-KEY (VIDEO EXTRA smoke gate, dogfood 5b50f8bb57ac, round 5 step 12): Cmd-N showed Home's agent page (a
/// Chromium page in its own child window), then Ctrl-` asked for a new terminal tab that the window did not show yet.
/// The focus waited for it and still resolved the agent page, and the wait moved no responder: the page window kept the
/// keys, so the line typed for the new terminal went to the page window instead of the cmux window's creation hold.
/// Through `FocusMachine` (the window's focus machine): a wait for another tab is a responder change in the same
/// reduction (`FocusEffectApplier` then takes the keys from the page).
struct FocusWaitLeavesPageTests {
    private func homeFocused() -> (FocusMachine, FocusState) {
        let machine = FocusMachine()
        var state = FocusState()
        let home = FocusTopology.Pane(id: "home", tabs: [.init(id: "home-tab", kind: .agent)], selected: "home-tab")
        _ = machine.send(.topology(FocusTopology(workspace: "w", panes: [home])), into: &state)
        return (machine, state)
    }

    private func movesResponder(_ effects: [FocusEffect]) -> Bool {
        effects.contains { if case .moveResponder = $0 { true } else { false } }
    }

    @Test func aWaitForANewTabMovesTheResponderOffThePageInItsTurn() throws {
        let (machine, home) = homeFocused()
        var state = home
        #expect(state.resolved == .agentPage(pane: "home", tab: "home-tab"))
        _ = machine.send(.beginIntent, into: &state)
        let effects = try #require(machine.send(.expect(.tab("new-term"), target: .content, generation: state.generation), into: &state)).effects
        #expect(state.expectation != nil, "the focus does not wait for the new terminal")
        #expect(movesResponder(effects), "the wait left the responder on Home's page, whose window keeps the keys: \(effects)")
    }

    @Test func aWaitThatANewerIntentEndsGivesThePageItsTargetAgain() throws {
        let (machine, home) = homeFocused()
        var state = home
        _ = machine.send(.beginIntent, into: &state)
        _ = machine.send(.expect(.tab("new-term"), target: .content, generation: state.generation), into: &state)
        let effects = try #require(machine.send(.beginIntent, into: &state)).effects
        #expect(state.expectation == nil)
        #expect(movesResponder(effects), "the wait ended without landing and Home's page did not get its target back: \(effects)")
    }
}
