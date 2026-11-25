import Foundation

// The sidebar document is one per home session, shared by every window, but
// a workspace belongs to one window (WindowRegistry). A workspace item in the
// band (Add to Top, a drop on the band, a pin, a custom section) draws only in
// the window that owns its workspace: a new window starts with its own workspace alone,
// and a workspace dragged to another window leaves this window's band too.
extension SidebarLayoutDocument {
    /// The layout one window draws: without the workspace items of any items
    /// section (top or scrolling) whose ref value `ownedElsewhere` (another
    /// window owns that workspace). Built-ins, apps, links, closed workspaces
    /// and the sections themselves stay.
    /// The stored document is not changed (no user data is removed).
    /// `room`: the window's space; an item of another space (`LayoutItem.room`, a Pinned link) leaves too. `spaces`:
    /// the spaces that exist; an item of one that is gone is the default space's (`SidebarDocItem.owningRoom`).
    public nonisolated func scopedToWindow(ownedElsewhere: (String) -> Bool, room: String? = nil, spaces: Set<String>? = nil) -> SidebarLayoutDocument {
        var result = self
        for index in result.sections.indices where result.sections[index].content == .items {
            result.sections[index].items.removeAll { item in
                if let room, let own = item.room, SidebarDocItem.owningRoom(own, spaces: spaces) != room { return true }
                return item.ref.kind == LayoutItemRef.workspaceKind && ownedElsewhere(item.ref.value)
            }
        }
        return result
    }
}
