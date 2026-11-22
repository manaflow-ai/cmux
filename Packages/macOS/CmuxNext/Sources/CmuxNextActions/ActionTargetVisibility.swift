// Target-aware context menu rows: a row that does nothing on the
// right-clicked target (Remove Icon on an object that shows no icon) is
// left out of that target's menu, as macOS menus leave out what does not
// apply. The palette, the CLI and MCP keep the action. A separate type
// keeps ActionRegistry within its size budget (as ActionTargetTitles does).
// lint:allow namespace-type — stateless action visibility helpers are intentionally a namespace.
@MainActor
public enum ActionTargetVisibility {
    /// Leaves a bound action out of a target's context menu when `hidden`
    /// returns true for that target.
    public static func hide(_ id: ActionID, in registry: ActionRegistry, when hidden: @escaping @MainActor (ActionInvocation) -> Bool) {
        guard var action = registry.action(for: id) else { return }
        action.targetHidden = hidden
        registry.register(action)
    }

    /// Whether the menu row of `id` is left out for `invocation`'s target.
    static func isHidden(_ id: ActionID, invocation: ActionInvocation, in registry: ActionRegistry) -> Bool {
        registry.action(for: id)?.targetHidden?(invocation) ?? false
    }
}
