/// What a context menu row implies and offers, without the registry: ``ActionRegistry`` builds its
/// menus with these, and the checked-in exports (``ContextMenuCatalog/exportJSON``) state them, on the
/// Mac and in the Linux build of the exports alike.
nonisolated enum MenuChoiceRules {
    /// The focus a right-click in `context` implies for its rows' availability.
    static func impliedContext(for context: ActionMenuContext) -> ActionContext {
        switch context {
        case .browserPage, .browserLink, .browserImage, .browserSelection: .browserFocused
        case .terminalSelection: .terminalFocused
        case .agentChat, .priorityRow: .agentPaneFocused
        // A right-clicked row is the explorer's even while another view has the keyboard.
        case .fileExplorerRow: .fileExplorerFocused
        default: []
        }
    }

    /// The values a choices submenu lists for `argument`: an enumeration's cases, else its pinned suggestions.
    static func menuChoices(_ argument: ActionArgument) -> (ActionArgument, [ActionEnumCase])? {
        if case .enumeration(let cases) = argument.kind { return (argument, cases) }
        if let suggestions = argument.suggestions, !suggestions.pinned.isEmpty { return (argument, suggestions.pinned) }
        return nil
    }
}
