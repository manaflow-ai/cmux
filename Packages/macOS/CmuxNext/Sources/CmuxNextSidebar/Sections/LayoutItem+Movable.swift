import Foundation

extension LayoutItemRef {
    /// False for Home, which stays on top of the sidebar: a press on it never drags and nothing drops above it.
    ///
    /// The one movability policy of every sidebar item: the band, a block's tiles and rows, and the drop table read it
    /// (`SidebarItemRowView.isMovable`, `SidebarRegionView.dragMoved`, `SidebarListBlocks.keepingFixed`). Home is the
    /// first-party app `cmux/home` (`SidebarLayoutDocument.homeRef`) or the older built-in `home`.
    /// Lawrence 2026-10-30: "i tried to drag home around and now it's stuck in this state".
    var isMovable: Bool {
        self != SidebarLayoutDocument.homeRef && builtIn != .home
    }
}

extension LayoutItem {
    /// Whether a press on this item may drag it: a client-only item (What's New) and Home never move.
    var isMovable: Bool { !id.isTransient && ref.isMovable }
}

extension LayoutItem {
    /// Whether a release beside the sidebar takes this item off it, as Remove from Sidebar does: every item that moves
    /// (an app, a built-in, a link, a room) except a workspace or tab, which a drag out of the sidebar carries elsewhere.
    /// The item menu keeps one remove row; the drag is the other way (Leo 2026-11-22: "just move it yourself").
    public var comesOffOnDragOut: Bool {
        isMovable && ref.kind != LayoutItemRef.workspaceKind && ref.kind != LayoutItemRef.tabKind
    }
}
