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

    public var maxY: CGFloat { y + height }
}
