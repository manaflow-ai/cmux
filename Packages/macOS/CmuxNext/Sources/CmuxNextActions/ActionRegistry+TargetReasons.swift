// Target-aware "cannot run" reasons: an action that is available in general
// but not on one target (the screen's only column cannot be pinned) shows as
// disabled with the reason in that target's context menu, instead of failing
// after the click. `perform` refuses such an invocation with the reason, so
// the palette, the CLI and MCP report it too. A separate type keeps
// ActionRegistry within its size budget.
// lint:allow namespace-type — stateless action reason helpers are intentionally a namespace.
@MainActor
public enum ActionTargetReasons {
    /// Sets the target-aware reason of a bound action.
    public static func set(_ id: ActionID, in registry: ActionRegistry, _ reason: @escaping @MainActor (ActionInvocation) -> String?) {
        guard var action = registry.action(for: id) else { return }
        action.targetUnavailableReason = reason
        registry.register(action)
    }

    /// Adds a target-aware reason in front of the one already set: `reason`
    /// answers first, the earlier reason when it returns nil. Two owners
    /// (lone columns, app screens) can then disable the same action.
    public static func add(_ id: ActionID, in registry: ActionRegistry, _ reason: @escaping @MainActor (ActionInvocation) -> String?) {
        let earlier = registry.action(for: id)?.targetUnavailableReason
        set(id, in: registry) { invocation in reason(invocation) ?? earlier?(invocation) }
    }

    /// The general reason, else the reason for `invocation`'s target.
    public static func reason(for id: ActionID, invocation: ActionInvocation, in registry: ActionRegistry) -> String? {
        registry.unavailableReason(for: id) ?? registry.action(for: id)?.targetUnavailableReason?(invocation)
    }

    /// `canPerform(_:)` for one invocation's target.
    public static func canPerform(_ id: ActionID, invocation: ActionInvocation, in registry: ActionRegistry) -> Bool {
        registry.canPerform(id) && registry.action(for: id)?.targetUnavailableReason?(invocation) == nil
    }

    /// Refuses `invocation` with the action's target reason, if it has one.
    static func refuses(_ action: Action, _ invocation: ActionInvocation, in registry: ActionRegistry) -> Bool {
        guard let reason = action.targetUnavailableReason?(invocation) else { return false }
        registry.refuse(reason)
        return true
    }
}
