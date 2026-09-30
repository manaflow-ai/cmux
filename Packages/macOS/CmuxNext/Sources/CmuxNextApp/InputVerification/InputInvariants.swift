import CmuxNextActions

/// The global input invariants (plans/cmux-next/input-spec.md), as pure
/// checks. The live monitor, `debug.focus`, replay and the model fuzzer all
/// call these, so a rule has one definition.
nonisolated enum InputInvariants {
    // MARK: Model (F)

    /// Invariants every focus state must satisfy.
    static func model(_ state: FocusState, window: String? = nil) -> [InputViolation] {
        var out: [InputViolation] = []
        func fail(_ invariant: InputInvariant, _ detail: String) {
            out.append(InputViolation(invariant: invariant, window: window, detail: detail))
        }
        let resolved = state.resolved
        if let top = state.overlays.last, resolved != .overlay(top) {
            fail(.overlayOnTop, "resolved \(resolved.kind) with overlay \(top.rawValue) open")
        }
        if let pane = state.pane, !state.topology.contains(pane: pane) {
            fail(.livePane, "focused pane \(pane) is not in the topology")
        }
        if let pane = resolved.pane {
            if pane != state.pane { fail(.livePane, "resolved pane \(pane) != focused pane \(state.pane ?? "nil")") }
            if let tab = resolved.tab, state.topology.pane(pane)?.selected != tab {
                fail(.livePane, "resolved tab \(tab) is not the selection of \(pane)")
            }
        }
        if state.pane == nil, state.target.isPaneScoped, !state.topology.panes.isEmpty {
            fail(.paneWhenPanes, "\(state.topology.panes.count) panes and no focused pane")
        }
        let selectedKind = state.pane.flatMap { state.topology.pane($0)?.selectedTab?.kind }
        switch resolved {
        case .terminal where selectedKind != .terminal,
             .browserPage where selectedKind != .browser,
             .addressBar where selectedKind != .browser,
             .findBar where selectedKind != .browser:
            fail(.targetKind, "\(resolved.kind) on a \(selectedKind?.rawValue ?? "missing") tab")
        default:
            break
        }
        if state.target == .addressBar || state.target == .findBar, selectedKind != .browser {
            fail(.targetKind, "target \(state.target) kept on a \(selectedKind?.rawValue ?? "missing") tab")
        }
        if let expectation = state.expectation, expectation.generation != state.generation {
            fail(.noStaleExpectation, "expectation \(expectation.key) from generation \(expectation.generation) at \(state.generation)")
        }
        let dead = state.browserFocusMode.subtracting(state.topology.allTabIDs)
        if !dead.isEmpty { fail(.focusModeLive, "focus mode on missing tabs \(dead.sorted())") }
        return out
    }

    // MARK: Transitions (T)

    /// Rules about how one event may change the state.
    static func transition(from old: FocusState, _ event: FocusEvent, to new: FocusState, window: String? = nil) -> [InputViolation] {
        var out: [InputViolation] = []
        func fail(_ invariant: InputInvariant, _ detail: String) {
            out.append(InputViolation(invariant: invariant, window: window, detail: detail))
        }
        let moved = old.pane != new.pane || old.target != new.target
        switch event {
        case .expect(_, _, let generation) where generation != old.generation:
            if moved || new.expectation != old.expectation { fail(.noSteal, "stale expect (\(generation) at \(old.generation)) changed focus") }
        case .windowKey, .appActive, .overlayOpened, .overlayClosed, .contentPresented:
            if moved { fail(.passiveEvents, "\(event) moved focus \(old.pane ?? "nil")/\(old.target) -> \(new.pane ?? "nil")/\(new.target)") }
        case .responder where !old.overlays.isEmpty:
            if moved { fail(.passiveEvents, "responder report under an overlay moved focus") }
        default:
            break
        }
        if new.generation < old.generation, old.generation != .max {
            fail(.monotonicGeneration, "generation \(old.generation) -> \(new.generation)")
        }
        return out
    }

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
