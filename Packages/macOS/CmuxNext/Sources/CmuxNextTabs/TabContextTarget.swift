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
    /// Empty strip space (or the new tab button).
    case emptyStrip
}

/// Builds the menu for a right-click. Return nil for no menu.
public typealias TabContextMenuProvider = @MainActor (TabContextTarget) -> NSMenu?
