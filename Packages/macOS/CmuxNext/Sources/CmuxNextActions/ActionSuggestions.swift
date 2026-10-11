import Foundation

/// Known values of a free-text argument. The App supplies the full list for
/// `source` (`ActionRegistry.argumentSuggestions`, `PaletteSources`); the
/// palette offers it with type-to-search and still accepts other text; a
/// context menu offers `pinned` plus an item that opens the full list.
public nonisolated struct ActionSuggestions: Sendable, Hashable {
    /// Which list the App supplies (`ghosttyThemes`).
    public let source: String
    /// Shown first in pickers and as the context menu's items.
    public let pinned: [ActionEnumCase]
    /// Title of the palette row that takes other text (a light/dark pair).
    public let otherTitle: String?

    public init(source: String, pinned: [ActionEnumCase], otherTitle: String? = nil) {
        self.source = source
        self.pinned = pinned
        self.otherTitle = otherTitle
    }

    /// Every Ghostty theme (the App lists them).
    public static let ghosttyThemes = "ghosttyThemes"
    /// Items `sidebar.item.add` puts in the sidebar: the built-ins, plus
    /// `workspace:<id>` and `app:<publisher>/<name>` typed as text.
    public static let sidebarItems = "sidebarItems"
}
