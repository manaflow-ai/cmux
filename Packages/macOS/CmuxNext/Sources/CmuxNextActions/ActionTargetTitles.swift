import AppKit

// Target-aware context menu titles: a toggle reads as the change it makes
// on the right-clicked target ("Pin Tab" or "Unpin Tab", Chrome parity,
// PINNED-ITEMS-END-TO-END) while the palette, the CLI and MCP keep the
// catalog title and id. A separate type keeps ActionRegistry within its
// size budget (as ActionTargetReasons does).
// lint:allow namespace-type — stateless action title helpers are intentionally a namespace.
@MainActor
public enum ActionTargetTitles {
    /// Sets the context menu title of a bound action for each target.
    public static func set(_ id: ActionID, in registry: ActionRegistry, _ title: @escaping @MainActor (ActionInvocation) -> String?) {
        guard var action = registry.action(for: id) else { return }
        action.targetTitle = title
        registry.register(action)
    }

    /// Sets whether a bound toggle is on for each target; its context menu
    /// row shows a checkmark while it is.
    public static func setState(_ id: ActionID, in registry: ActionRegistry, _ state: @escaping @MainActor (ActionInvocation) -> Bool?) {
        guard var action = registry.action(for: id) else { return }
        action.targetState = state
        registry.register(action)
    }

    /// Applies the target's title, its toggle state and the target-aware
    /// disabled reason (Chromium in a build without CEF) to a context menu item.
    static func decorate(_ item: NSMenuItem, id: ActionID, invocation: ActionInvocation, in registry: ActionRegistry) {
        let action = registry.action(for: id)
        if let title = action?.targetTitle?(invocation) { item.title = title }
        if let on = action?.targetState?(invocation) { item.state = on ? .on : .off }
        if let reason = ActionTargetReasons.reason(for: id, invocation: invocation, in: registry) {
            item.subtitle = reason
            item.toolTip = reason
        }
    }
}
