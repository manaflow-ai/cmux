import CmuxNextFocus
import CmuxNextInputModel
import Testing
@testable import CmuxNextApp

/// The input rules as the invariant registry declares them (InputVerificationService.declareInvariants): one rule per
/// id, each running only its own family of `InputInvariants.world`, so together they find exactly what the whole
/// world check finds, and each finds only its own id.
struct InputInvariantRulesTests {
    private func window(_ id: String, _ resolved: FocusState.Resolved, isKey: Bool, responder: FocusEvent.Responder,
                        ghostty: [String] = [], presented: [String: String] = ["pane_a": "tab_t"]) -> InputObservation.Window {
        var model = FocusState()
        model.resolved = resolved
        model.underlying = resolved
        model.windowKey = isKey
        model.pane = "pane_a"
        model.topology = FocusTopology(workspace: "ws", panes: [FocusTopology.Pane(id: "pane_a", tabs: [FocusTopology.Tab(id: "tab_t", kind: .terminal)],
                                                                                   selected: "tab_t")], screens: [])
        return InputObservation.Window(id: id, model: model, responder: responder, isKey: isKey, layoutFocus: "pane_a",
                                       ghosttyFocused: ghostty, presented: presented, visible: true)
    }

    private var observations: [InputObservation] {
        let terminal = FocusState.Resolved.terminal(pane: "pane_a", tab: "tab_t")
        return [
            // In sync.
            InputObservation(windows: [window("w1", terminal, isKey: true, responder: .content(pane: "pane_a"), ghostty: ["tab_t"])],
                             keyWindow: .window("w1"), paletteOpen: false, activeWindow: "w1",
                             context: FocusState.Context(terminal: true), appActive: true),
            // Ghostty focus in a window that is not key, no key window while active, the context unpublished.
            InputObservation(windows: [window("w1", terminal, isKey: false, responder: .windowOrNone, ghostty: ["tab_t"]),
                                       window("w2", .none, isKey: false, responder: .windowOrNone, presented: [:])],
                             keyWindow: .none, paletteOpen: true, activeWindow: "w2", context: FocusState.Context(), appActive: true),
        ]
    }

    @Test func theDeclaredRulesTogetherFindWhatTheWorldCheckFinds() {
        for observation in observations {
            let declared = InputInvariants.worldRules.flatMap { InputInvariants.violations(of: $0, in: observation) }
            #expect(Set(declared) == Set(InputInvariants.world(observation).violations))
        }
    }

    @Test func eachDeclaredRuleFindsOnlyItsOwnID() {
        for observation in observations {
            for invariant in InputInvariants.worldRules {
                #expect(InputInvariants.violations(of: invariant, in: observation).allSatisfy { $0.invariant == invariant })
            }
        }
    }

    @Test func aBrokenObservationIsFoundByTheDeclaredRules() {
        let broken = observations[1]
        #expect(!InputInvariants.worldRules.flatMap { InputInvariants.violations(of: $0, in: broken) }.isEmpty)
    }

    @Test func aWindowThatDoesNotPresentItsTargetIsWaitedOnNotChecked() {
        let terminal = FocusState.Resolved.terminal(pane: "pane_a", tab: "tab_t")
        let pending = InputObservation(windows: [window("w1", terminal, isKey: true, responder: .windowOrNone, presented: ["pane_a": "tab_other"])],
                                       keyWindow: .window("w1"), paletteOpen: false, activeWindow: "w1",
                                       context: FocusState.Context(terminal: true), appActive: true)
        #expect(InputInvariants.unsettledWindows(pending) == ["w1"])
        #expect(InputInvariants.violations(of: .responderMatches, in: pending).isEmpty, "W1 waits for the presentation (W9)")
    }
}
