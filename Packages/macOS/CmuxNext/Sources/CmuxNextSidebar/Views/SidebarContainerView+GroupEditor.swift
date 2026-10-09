import AppKit

// The group editor's App side (cx-rcby): its action rows and what runs them.
extension SidebarContainerView {
    /// The group whose editor is open, if any.
    public var editingGroup: GroupID? { sidebarView.list.groupEditor.shownGroup }

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

    /// The editor's standard rows: New Workspace in Group, Move Group to New
    /// Window, Close Group; Ungroup, Delete Group, More Group Actions.
    public static func standardGroupEditorItems() -> [[SidebarGroupEditorItem]] {
        SidebarGroupEditing.standardItems()
    }
}
