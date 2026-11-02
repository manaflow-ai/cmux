public import CmuxNextDesign
public import CoreGraphics
import Foundation

/// Identity of a rendered row. Views are keyed by this across reloads so
/// moves animate instead of re-creating.
public nonisolated enum SidebarRowKey: Hashable, Sendable {
    case section(SectionID)
    case group(GroupID)
    case workspace(WorkspaceID)
    /// Drop zone shown for an empty section while dragging (pinned area).
    case emptySection(SectionID)
    /// The quiet row under an open group with no members (`SidebarLayout+EmptyGroup`): a drop over it goes into the group.
    case emptyGroup(GroupID)
    /// Group by Folder's header over one folder's loose rows ("" = none).
    case folder(SectionID, String)
    /// Group by Status's header over one status section's rows (`SidebarLayout+Status`).
    case status(SidebarStatusSection)
    /// A document item listed as a row (`SidebarNode.item`): its item id.
    case item(String)
    /// A document section's items in its own arrangement (tiles, a grid, a
    /// line, item rows), drawn by one region: the section id.
    case block(String)
    /// The "Done (N)" row that holds a list's workspaces marked Done (`SidebarLayout+DoneFold`).
    case doneFold(SidebarDoneFoldID)
    /// The "Show N more" row past a long list's first rows (`sidebar.groupRowLimit`), "Show fewer" once opened.
    case showMore(SidebarDoneFoldID)
}

/// One laid-out row in document (flipped) coordinates.
public nonisolated struct SidebarRow: Hashable, Sendable {
    public var key: SidebarRowKey
    public var y: CGFloat
    public var height: CGFloat
    public var section: SectionID
    /// Containing group for a workspace row; the group itself for a header.
    public var group: GroupID?
    /// Index among the container's siblings, counting only rows not being
    /// dragged. For group headers this is the group's index in the section.
    public var siblingIndex: Int
    /// For a grouped workspace: the group's index in its section.
    public var parentIndex: Int?
    public var isLastInGroup: Bool
    public var isCollapsed: Bool
    /// Children (groups) or nodes (sections), counting only non-dragged ones.
    public var childCount: Int
    /// Color of the containing group, drawn as a rail beside grouped rows.
    public var groupColor: GroupColor?
    /// A machine header standing for the only machine: titled "Projects".
    public var titlesProjects = false
    /// Group levels the row sits in (remote-groups-DESIGN.md slice 2): 0 at the top level, a group
    /// header its group's level, a member one more. The list indents each level below the first by one
    /// gutter (`SidebarStyle.groupOffset`).
    public var depth: Int = 0
    /// A workspace row that is its group's one row (`SidebarLayout.soleMember`): a group of one member titled as the
    /// group draws no header, so this row carries the group's line and its menu the group's actions.
    public var standsForGroup = false
    /// What a workspace row draws (`WorkspaceRowContent`); nil for other rows.
    public var content: WorkspaceRowContent? = nil
    /// A workspace row's tab count, when `sidebar.workspaceRow.tabCount` is on.
    public var tabCount: Int? { content?.tabCount }
    /// A workspace row's second line.
    public var detail: String? { content?.detail }

    public var maxY: CGFloat { y + height }
}
