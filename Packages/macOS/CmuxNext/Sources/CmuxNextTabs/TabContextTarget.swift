public import AppKit

/// What a right-click landed on. The App builds the menu from its action
/// registry; the strip never constructs menu items itself.
public enum TabContextTarget: Hashable, Sendable {
    /// A tab. `selection` is every tab the action should apply to, the
    /// clicked tab first (multi-select adds more later).
    case tab(TabID, selection: [TabID])
    /// A group chip in a strip.
    case group(TabGroupID)
    /// A chip in the saved groups bar.
    case savedGroup(TabGroupID)
    /// Empty strip space.
    case emptyStrip
    /// The new tab (+) button: a click or right-click shows this menu (which
    /// kind of tab to open). Without a menu a click opens a tab directly.
    case newTabButton
}

/// Builds the menu for a right-click. Return nil for no menu.
public typealias TabContextMenuProvider = @MainActor (TabContextTarget) -> NSMenu?
