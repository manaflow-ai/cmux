public import CmuxNextDesign
import Foundation

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
    case createGroup(GroupID, name: String, color: GroupColor, workspaces: [WorkspaceID])
    case renameGroup(GroupID, String)
    case setGroupColor(GroupID, GroupColor)
    /// Dissolve a group, leaving its workspaces in place.
    case ungroup(GroupID)
    /// Pin (save) or unpin a group.
    case setGroupPinned(GroupID, Bool)
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
    /// Run an item's trailing control (`SidebarItemInfo.accessory`).
    case activateItemAccessory(LayoutItemID)
    /// Change the section layout; the App sends it to the workspace store.
    case layout(SidebarLayoutOp)
    /// Collapse or expand a titled section (client view state).
    case toggleLayoutSection(LayoutSectionID)
}
