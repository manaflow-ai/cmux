// Target-aware "cannot run" reasons: an action that is available in general
// but not on one target (the screen's only column cannot be pinned) shows as
// disabled with the reason in that target's context menu, instead of failing
// after the click. `perform` refuses such an invocation quietly: the palette,
// the CLI and MCP get the reason back, and a keyboard shortcut or menu run of
// the disabled action does nothing, never a toast that sends the person
// elsewhere (Leo 2026-11-17, "just... stop showijg the toggle"). A separate type keeps
// ActionRegistry within its size budget.
// lint:allow namespace-type — stateless action reason helpers are intentionally a namespace.
@MainActor
public enum ActionTargetReasons {
    /// Sets the target-aware reason of a bound action.
    public static func set(_ id: ActionID, in registry: ActionRegistry, _ reason: @escaping @MainActor (ActionInvocation) -> String?) {
        guard var action = registry.action(for: id) else { return }
        action.targetUnavailableReason = question(reason, in: registry)
        registry.register(action)
    }

    /// `rule` as a question. Every rule an action answers a question with (is its row left out for
    /// this target, why it cannot run here, its title, its check mark, its chosen value) is kept
    /// this way at its one write (here, `ActionTargetVisibility`, `ActionTargetTitles`): a lookup
    /// in it that refuses (a tab the tree no longer has) tells nobody, since nobody ran an action.
    /// Only a run refuses (``refuses(_:_:in:)``).
    static func question<Input, Answer>(_ rule: @escaping @MainActor (Input) -> Answer,
                                        in registry: ActionRegistry) -> @MainActor (Input) -> Answer {
        { [weak registry] input in
            guard let registry else { return rule(input) }
            return registry.withoutRefusals { rule(input) }
        }
    }

    /// ``question(_:in:)`` for a rule about the focused object (a palette row's rules).
    static func focusQuestion<Answer>(_ rule: @escaping @MainActor () -> Answer, in registry: ActionRegistry) -> @MainActor () -> Answer {
        { [weak registry] in
            guard let registry else { return rule() }
            return registry.withoutRefusals { rule() }
        }
    }

    /// The general reason, else the reason for `invocation`'s target.
    public static func reason(for id: ActionID, invocation: ActionInvocation, in registry: ActionRegistry) -> String? {
        registry.unavailableReason(for: id) ?? registry.action(for: id)?.targetUnavailableReason?(invocation)
    }

    /// `canPerform(_:)` for one invocation's target.
    public static func canPerform(_ id: ActionID, invocation: ActionInvocation, in registry: ActionRegistry) -> Bool {
        registry.canPerform(id, in: invocation.keyContext) && registry.action(for: id)?.targetUnavailableReason?(invocation) == nil
    }

    /// Refuses `invocation` with the action's target reason, if it has one. Quiet: a caller gets
    /// the reason; a shortcut or menu run shows nothing, as for an action that is disabled
    /// (`bind(_:unavailable:)`) or out of context (`requires`).
    static func refuses(_ action: Action, _ invocation: ActionInvocation, in registry: ActionRegistry) -> Bool {
        guard let reason = action.targetUnavailableReason?(invocation) else { return false }
        registry.refuse(reason, quiet: true)
        return true
    }
}
