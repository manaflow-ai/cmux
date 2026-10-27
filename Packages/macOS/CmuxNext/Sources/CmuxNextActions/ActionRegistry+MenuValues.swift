import Foundation

// What a menu shows, apart from the AppKit rows CmuxNextActionsAppKit builds from it: the surface
// export (ContextMenuCatalog+Export) and the target choices read these too.

extension ActionRegistry {
    /// Focus facts a right-click implies (right-clicking a page means a
    /// browser is the target even if a terminal has focus).
    package nonisolated static func impliedContext(for context: ActionMenuContext) -> ActionContext {
        switch context {
        case .browserPage, .browserLink, .browserImage, .browserSelection: .browserFocused
        case .terminalSelection: .terminalFocused
        case .agentChat, .priorityRow: .agentPaneFocused
        // A right-clicked row is the explorer's even while another view has the keyboard.
        case .fileExplorerRow: .fileExplorerFocused
        default: []
        }
    }

    /// The menu items of an argument: every case of an enumeration, or the
    /// pinned values of a suggested string.
    nonisolated static func menuChoices(_ argument: ActionArgument) -> (ActionArgument, [ActionEnumCase])? {
        if case .enumeration(let cases) = argument.kind { return (argument, cases) }
        if let suggestions = argument.suggestions, !suggestions.pinned.isEmpty { return (argument, suggestions.pinned) }
        return nil
    }
}

extension ActionSuggestions {
    /// The last row of a choices submenu of suggested values: the full list, with type-to-search,
    /// in the palette.
    package nonisolated static var moreTitle: String {
        String(localized: "argument.value.more", defaultValue: "More…", table: "ThemeActions", bundle: .module)
    }
}
