import Foundation

extension LayoutItemRef {
    /// True when a sidebar item with this ref switches on mouse-down, as a workspace row and a pane tab do.
    ///
    /// The one press policy of every sidebar item: the band, a block's tiles and the list's item rows
    /// all read it (`SidebarItemRowView`, `SidebarListView+Mouse`). An item that only changes what the
    /// window shows switches on the press: Home, the App Store, a pinned workspace, tab or space tile
    /// (Lawrence 2026-10-19: "Mouse down to focus"). A press that turns into a drag still moves the
    /// item (the switch already happened, as with a dragged workspace row). Every other item
    /// (Settings, launchers, a link that may open a tab, a saved group that reopens, other apps)
    /// still acts on release, so a press the user meant as a move never runs it.
    var activatesOnPress: Bool {
        if let builtIn { return builtIn == .home || builtIn == .appStore }
        switch kind {
        case Self.workspaceKind, Self.tabKind, Self.roomKind:
            return true
        case Self.appKind:
            return value == SidebarLayoutDocument.firstPartyApps[.home] || value == SidebarLayoutDocument.firstPartyApps[.appStore]
        default:
            return false
        }
    }
}
