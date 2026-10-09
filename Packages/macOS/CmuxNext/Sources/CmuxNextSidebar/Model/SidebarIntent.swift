public import CmuxNextDesign
public import Foundation

/// User intents emitted by the sidebar. The App layer forwards them to the
/// owning daemon; `SidebarModel.apply(_:)` applies them locally (optimistic
/// update and the standalone mock).
public nonisolated enum SidebarIntent: Hashable, Sendable {
    /// Activate a workspace (the selection's primary item).
    case select(WorkspaceID)
    /// Activate a tab listed beneath a workspace.
    case selectTab(workspace: WorkspaceID, tab: TabID)
    /// Move a listed tab into another workspace.
    case moveTab(TabID, from: WorkspaceID, to: WorkspaceID)
    /// Move workspaces, in tree order, to a position. Covers reorder, moving
    /// into or out of groups, pinning, and unpinning.
    case reorder([WorkspaceID], to: DropPosition)
    /// Append workspaces to a group.
    case move([WorkspaceID], toGroup: GroupID)
    /// Move a group within its section. `index` excludes the group itself.
    case reorderGroup(GroupID, index: Int)
    /// Create a group holding the given workspaces. The UI mints the id.
    /// The group forms where `anchor` is (a row dropped onto another forms
    /// it at the target row), else at the first workspace in tree order.
    /// `collapsed` restores a group folded (undo of Ungroup).
    case createGroup(GroupID, name: String, color: GroupColor, workspaces: [WorkspaceID], anchor: WorkspaceID? = nil, collapsed: Bool = false)
    case renameGroup(GroupID, String)
    /// The group's name editor closed (commit or cancel). The App removes a
    /// group made with no member that is still empty (cx-rcby). No local change.
    case groupEditorEnded(GroupID)
    case setGroupColor(GroupID, GroupColor)
    /// Dissolve a group, leaving its workspaces in place.
    case ungroup(GroupID)
    /// Pin (save) or unpin a group.
    case setGroupPinned(GroupID, Bool)
    /// Set a group's icon to the shared icon string (one emoji or an SF
    /// Symbol name); nil removes it.
    case setGroupIcon(GroupID, String?)
    /// Close every workspace in the group. A pinned group stays as an empty,
    /// collapsed saved group; an unpinned one disappears.
    case closeGroup(GroupID)
    /// Reopen an empty pinned group (clicking its header). The App restores
    /// its workspaces; the sidebar applies no local change.
    case openGroup(GroupID)
    case toggleCollapse(CollapseTarget)
    case close([WorkspaceID])
    case rename(WorkspaceID, String)
    /// Set a swatch color (nil restores the default symbol icon).
    case setColor([WorkspaceID], GroupColor?)
    case setIcon([WorkspaceID], WorkspaceIcon)
    case setPinned([WorkspaceID], Bool)
    /// New workspace on a machine (nil = the machine of the active workspace,
    /// else local), optionally inside a group.
    case newWorkspace(machine: MachineID?, group: GroupID?)
    /// Show another profile in this window (dot click, swipe).
    case switchProfile(ProfileKey)
    /// Create a profile (the bar's "+").
    case newProfile
    /// Move a profile to an insertion index (dot drag).
    case reorderProfile(ProfileKey, index: Int)
    /// Run an item of a pinned section (a built-in's action, a pinned
    /// workspace). plans/cmux-next/sidebar-sections.md
    case activateItem(LayoutItemID, opensWorkspace: Bool = false)
    /// The update card's button: install the staged update and relaunch
    /// (`SidebarModel.updateCard`).
    case installUpdate
    /// The update card's Automatic Updates checkbox.
    case setAutomaticUpdates(Bool)
    /// A link in the update card's popover (a pull request, the release notes).
    case openUpdateLink(URL)
    /// The tip card's "Try It": run the tip's feature.
    case tryTip(String)
    /// The tip card's x: never show this tip again.
    case dismissTip(String)
    /// The "cmux Updated!" card's "See What's New" row (`updates.whatsNew`).
    case openWhatsNew
    /// The "cmux Updated!" card's "Share cmux" row (`app.shareCmux`).
    case shareCmux
    /// The "cmux Updated!" card's x: this version is seen.
    case dismissUpdated
    /// Change the section layout; the App sends it to the workspace store.
    case layout(SidebarLayoutOp)
    /// Workspace rows dropped on a top section (the pinned tiles or the top
    /// rows) at `index`: the App adds each there as a layout item
    /// (drop-to-pin, PINNED-ITEMS-END-TO-END P2). No local change.
    case dropOnLayoutSection([WorkspaceID], section: LayoutSectionID, index: Int)
    /// Collapse or expand a titled section (client view state).
    case toggleLayoutSection(LayoutSectionID)
}
