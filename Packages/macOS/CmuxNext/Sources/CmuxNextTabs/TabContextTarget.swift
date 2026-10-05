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
    /// The new tab (+) button's menu (which kind of tab to open), shown on
    /// right-click and press-and-hold. A plain click opens a tab directly.
    case newTabButton
    /// The menu of trailing button `id` (`TabStripButton.menu`): on click
    /// for `.primary`, on right-click and press-and-hold for `.secondary`.
    case trailingButton(String)
}

/// Builds the menu for a right-click. Return nil for no menu.
public typealias TabContextMenuProvider = @MainActor (TabContextTarget) -> NSMenu?
