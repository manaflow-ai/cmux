public import CmuxNextDesign
import Foundation

/// What Ungroup and Delete Group take away from a group (RECOVERABLE-BY-DEFAULT):
/// its name, color, collapse state and members in order. Captured before
/// the group goes; `intent(newID:)` forms the group again at its first
/// member's place, so the undo toast and Cmd-Z restore it as it was.
public nonisolated struct SidebarGroupRestore: Hashable, Sendable {
    public var name: String
    public var color: GroupColor
    public var isCollapsed: Bool
    public var members: [WorkspaceID]

    /// The restore record of group `id` in `sections`, nil when it is not there.
    public static func capture(_ id: GroupID, in sections: [SidebarSection]) -> SidebarGroupRestore? {
        for section in sections {
            for case let .group(group) in section.nodes where group.id == id {
                return SidebarGroupRestore(name: group.name, color: group.color, isCollapsed: group.isCollapsed,
                                           members: group.workspaces.map(\.id))
            }
        }
        return nil
    }

    /// The one intent that forms the group again under `newID`.
    public func intent(newID: GroupID) -> SidebarIntent {
        .createGroup(newID, name: name, color: color, workspaces: members, anchor: members.first, collapsed: isCollapsed)
    }
}
