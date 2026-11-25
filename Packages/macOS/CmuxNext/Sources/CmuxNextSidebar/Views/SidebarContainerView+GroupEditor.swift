public import AppKit

// The group editor's App side (cx-rcby): its action rows and what runs them.
extension SidebarContainerView {
    /// The group whose editor is open, if any.
    public var editingGroup: GroupID? { sidebarView.list.groupEditor.shownGroup }

    /// What draws the group editor (the App's page in a native popup); held weakly.
    public var groupEditorSurface: SidebarGroupEditorSurface? {
        get { sidebarView.list.groupEditor.surface }
        set { sidebarView.list.groupEditor.surface = newValue }
    }

    /// The group editor's action rows for a group; nil shows
    /// `standardGroupEditorItems()`. A row's id is an action id.
    public var groupEditorItems: ((GroupID) -> [[SidebarGroupEditorItem]])? {
        get { sidebarView.list.groupEditorItems }
        set { sidebarView.list.groupEditorItems = newValue }
    }

    /// A group editor row was chosen: the App runs the action on the group.
    public var onGroupEditorItem: ((GroupID, String) -> Void)? {
        get { sidebarView.list.onGroupEditorItem }
        set { sidebarView.list.onGroupEditorItem = newValue }
    }

    /// The group editor's Sort menu for a group: the App builds it from the registry (`workspaceGroup.setSort`'s
    /// choices), so a pick runs the same action as the group menu, the palette and the CLI.
    public var groupSortMenu: ((GroupID) -> NSMenu?)? {
        get { sidebarView.list.groupSortMenu }
        set { sidebarView.list.groupSortMenu = newValue }
    }

    /// The editor row that shows the group's full menu (the sidebar shows it).
    public static var moreActionsItem: String { SidebarGroupEditing.moreActionsItem }
    /// Sent before the editor closes for a picker that still edits the group: keep a new empty group.
    public static var keepGroupItem: String { SidebarGroupEditing.keepGroupItem }

    /// The editor's standard rows: New Workspace in Group, Move to New Window, Close All in Group;
    /// Pin or Unpin Group (as `pinned` says), Move to Top, Sort; Ungroup, Delete Group. `shortcut` gives
    /// each row's action (by id) its current shortcut text.
    public static func standardGroupEditorItems(pinned: Bool = false, shortcut: (String) -> String? = { _ in nil })
        -> [[SidebarGroupEditorItem]] {
        SidebarGroupEditing.standardItems(pinned: pinned).map { section in
            section.map { item in
                var item = item
                item.shortcut = shortcut(item.id)
                return item
            }
        }
    }
}
