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

    /// Sets whether a bound toggle is on for the focused object; its palette
    /// row shows a check while it is. `state` must not refuse (no HUD while
    /// the palette builds its rows).
    public static func setPaletteState(_ id: ActionID, in registry: ActionRegistry, _ state: @escaping @MainActor () -> Bool) {
        guard var action = registry.action(for: id) else { return }
        action.paletteState = state
        registry.register(action)
    }

    /// Sets the current value of a bound action's choices argument for each target.
    public static func setChoiceState(_ id: ActionID, in registry: ActionRegistry, _ state: @escaping @MainActor (ActionTargetRef?) -> String?) {
        guard var action = registry.action(for: id) else { return }
        action.choiceState = state
        registry.register(action)
    }

    /// Sets the palette row's title of a bound action for the focused object;
    /// nil keeps the catalog title. The CLI and MCP keep the catalog title and id.
    public static func setPaletteTitle(_ id: ActionID, in registry: ActionRegistry, _ title: @escaping @MainActor () -> String?) {
        guard var action = registry.action(for: id) else { return }
        action.paletteTitle = title
        registry.register(action)
    }
}
