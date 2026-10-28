/// The one place a surface asks what an action's row says for a target: the palette (the focused
/// object), the main menu and the menu bar (the focused object), context menus (the clicked one).
extension ActionRegistry {
    /// The title an action shows for `invocation`'s target (nil target: the focused object).
    ///
    /// A bound target title wins (Hide <Section Name>); then a toggle's title for its state
    /// (Pin Workspace or Unpin Workspace, ``ActionToggleTitles``); else the catalog title.
    /// Lookups run under ``withoutRefusals(_:)``: a surface building its rows shows no notice.
    public func displayTitle(for id: ActionID, invocation: ActionInvocation = ActionInvocation()) -> String? {
        let action = action(for: id)
        return withoutRefusals {
            if let title = action?.targetTitle?(invocation) { return title }
            if let titles = descriptor(for: id)?.toggleTitles, let isOn = action?.targetState?(invocation) {
                return titles.title(isOn: isOn)
            }
            return title(for: id)
        }
    }

    /// The SF Symbol an action shows for `invocation`'s target: a toggle's symbol for its state
    /// when it declares one, else the catalog symbol.
    public func displaySymbol(for id: ActionID, invocation: ActionInvocation = ActionInvocation()) -> String? {
        guard let descriptor = descriptor(for: id) else { return nil }
        guard let titles = descriptor.toggleTitles, let state = action(for: id)?.targetState else { return descriptor.symbol }
        return withoutRefusals { state(invocation) }.flatMap(titles.symbol(isOn:)) ?? descriptor.symbol
    }

    /// Whether the action's title depends on its target (a target title or toggle titles), so a
    /// menu built once re-reads it each time it opens; other rows keep the title they were built with.
    public func hasDisplayTitle(_ id: ActionID) -> Bool {
        action(for: id)?.targetTitle != nil || descriptor(for: id)?.toggleTitles != nil
    }

    /// Whether a toggle names its state in its title, so a surface shows no check mark beside it.
    public func namesToggleState(_ id: ActionID) -> Bool {
        descriptor(for: id)?.toggleTitles != nil
    }
}
