// Target-aware context menu rows: a row that does nothing on the
// right-clicked target (Remove Icon on an object that shows no icon) is
// left out of that target's menu, as macOS menus leave out what does not
// apply; `hideFromMenus` leaves a row out of every menu, the menu bar's too.
// The palette, the CLI and MCP keep the action. A separate type
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

    /// Gates a bound action on what its target lacks (Open Desktop on a machine with no desktop):
    /// while `reason` returns a string the row is left out of that target's context menu, the
    /// palette collects a supported target when declared, otherwise disables the row with it, and every run (palette, CLI,
    /// MCP, keyboard) is refused with it. `reason` never refuses on its own.
    public static func gate(_ id: ActionID, in registry: ActionRegistry, reason: @escaping @MainActor (ActionInvocation) -> String?) {
        let quiet: @MainActor (ActionInvocation) -> String? = { [weak registry] invocation in registry?.withoutRefusals { reason(invocation) } }
        let earlier = registry.action(for: id)?.targetUnavailableReason
        ActionTargetReasons.set(id, in: registry) { quiet($0) ?? earlier?($0) }
        hide(id, in: registry) { quiet($0) != nil }
        ActionTargetTitles.setPaletteReason(id, in: registry) { quiet(ActionInvocation()) }
    }

    /// Leaves a bound action out of every menu, the menu bar's and the right-click ones, while `hidden`
    /// returns true; the palette, keys, the CLI and MCP keep offering it (the space rows while the person
    /// has one space). Read each time a menu is built or opens, so a change shows at the next look.
    public static func hideFromMenus(_ id: ActionID, in registry: ActionRegistry, when hidden: @escaping @MainActor () -> Bool) {
        guard var action = registry.action(for: id) else { return }
        let earlier = action.menuHidden
        action.menuHidden = { hidden() || earlier?() == true }
        registry.register(action)
    }

    /// Whether the menu row of `id` is left out for `invocation`'s target, or out of every menu now.
    static func isHidden(_ id: ActionID, invocation: ActionInvocation, in registry: ActionRegistry) -> Bool {
        guard let action = registry.action(for: id) else { return false }
        return action.menuHidden?() == true || action.targetHidden?(invocation) == true
    }

    /// Whether every menu leaves `id`'s row out now (``hideFromMenus(_:in:when:)``).
    static func isHiddenFromMenus(_ id: ActionID, in registry: ActionRegistry) -> Bool {
        registry.action(for: id)?.menuHidden?() == true
    }
}
