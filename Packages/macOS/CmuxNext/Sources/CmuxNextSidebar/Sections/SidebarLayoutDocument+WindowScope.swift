import Foundation

// The sidebar document is one per home session, shared by every window, but
// a workspace belongs to one window (WindowRegistry). A workspace item in the
// band (Add to Top, a drop on the band, a pin, a custom section) draws only in
// the window that owns its workspace: a new window starts with its own workspace alone,
// and a workspace dragged to another window leaves this window's band too.
// Every other pin (a closed workspace, a tab, a page, a space) belongs to the
// window it was made in (#26632, `WindowBandOwnership`).
extension SidebarLayoutDocument {
    /// The layout one window draws: without the workspace items of any items
    /// section (top or scrolling) whose ref value `ownedElsewhere` (another
    /// window owns that workspace). Built-ins, apps, links, closed workspaces
    /// and the sections themselves stay.
    /// The stored document is not changed (no user data is removed).
    public nonisolated func scopedToWindow(ownedElsewhere: (String) -> Bool) -> SidebarLayoutDocument {
        withoutItems(where: { $0.ref.kind == LayoutItemRef.workspaceKind && ownedElsewhere($0.ref.value) })
    }

    /// The layout one window draws: without the items of any items section that `hides`. The sections stay.
    public nonisolated func withoutItems(where hides: (LayoutItem) -> Bool) -> SidebarLayoutDocument {
        var result = self
        for index in result.sections.indices where result.sections[index].content == .items {
            result.sections[index].items.removeAll(where: hides)
        }
        return result
    }
}
