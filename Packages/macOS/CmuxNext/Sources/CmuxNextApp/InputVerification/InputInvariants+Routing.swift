import CmuxNextActions
import CmuxNextFocus

// The key routing invariants (K) read the app's `KeyRouter`, so they stay here; the model,
// transition and world checks are in CmuxNextFocus (`InputInvariants`).
nonisolated extension InputInvariants {
    // MARK: Key routing (K)

    /// The router's tier rules for one focus state.
    static func routing(_ state: FocusState, window: String? = nil) -> [InputViolation] {
        var out: [InputViolation] = []
        func fail(_ invariant: InputInvariant, _ detail: String) {
            out.append(InputViolation(invariant: invariant, window: window, detail: detail))
        }
        if !KeyRouter.allows(.system, focus: state) { fail(.systemTierAlways, "tier 0 refused at \(state.resolved.kind)") }
        if KeyRouter.allows(.navigation, focus: state) == state.isBrowserFocusModeActive {
            fail(.navigationTier, "tier 1 \(state.isBrowserFocusModeActive ? "ran in" : "refused outside") browser focus mode")
        }
        if KeyRouter.allows(.content, focus: state), state.resolved.isTextInput || state.isBrowserFocusModeActive {
            fail(.contentTierGuarded, "tier 2 allowed at \(state.resolved.kind)")
        }
        for tier in ActionKeyTier.allCases {
            if KeyRouter.allowsMenu(tier, focus: state, keyWindow: .content) != KeyRouter.allows(tier, focus: state) {
                fail(.menuMatchesRouter, "menu gate disagrees for tier \(tier) at \(state.resolved.kind)")
            }
            if tier == .content, KeyRouter.allowsMenu(tier, focus: state, keyWindow: .textPanel) {
                fail(.menuMatchesRouter, "tier 2 menu item allowed over a text panel")
            }
        }
        return out
    }

    /// Model, transition and routing checks for one reduction.
    static func step(from old: FocusState, _ event: FocusEvent, to new: FocusState, window: String? = nil) -> [InputViolation] {
        model(new, window: window) + transition(from: old, event, to: new, window: window) + routing(new, window: window)
    }
}
