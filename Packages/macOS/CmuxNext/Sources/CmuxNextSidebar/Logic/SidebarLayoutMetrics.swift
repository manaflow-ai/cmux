public import CoreGraphics
import Foundation

/// Row metrics. Values come from CmuxNextDesign `Metrics` tokens; see
/// `standard`. Kept as a plain value so layout stays pure.
public nonisolated struct SidebarLayoutMetrics: Hashable, Sendable {
    public var topPadding: CGFloat
    public var bottomPadding: CGFloat
    public var sectionHeaderHeight: CGFloat
    public var sectionSpacing: CGFloat
    public var groupHeaderHeight: CGFloat
    /// Workspace row with one line.
    public var rowHeight: CGFloat
    /// Workspace row with one live status line.
    public var rowHeightWithSubtitle: CGFloat
    /// Height of the status progress bar, its gap included.
    public var progressBarHeight: CGFloat
    /// The least a status line may take, from its font: a custom row height
    /// can bring the step between the two row heights below a line.
    public var minimumStatusLineHeight: CGFloat
    public var rowSpacing: CGFloat
    public var groupBottomPadding: CGFloat
    public var emptySectionHeight: CGFloat

    public init(
        topPadding: CGFloat, bottomPadding: CGFloat, sectionHeaderHeight: CGFloat, sectionSpacing: CGFloat,
        groupHeaderHeight: CGFloat, rowHeight: CGFloat, rowHeightWithSubtitle: CGFloat, progressBarHeight: CGFloat = 6,
        minimumStatusLineHeight: CGFloat = 0,
        rowSpacing: CGFloat, groupBottomPadding: CGFloat, emptySectionHeight: CGFloat
    ) {
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.sectionHeaderHeight = sectionHeaderHeight
        self.sectionSpacing = sectionSpacing
        self.groupHeaderHeight = groupHeaderHeight
        self.rowHeight = rowHeight
        self.rowHeightWithSubtitle = rowHeightWithSubtitle
        self.progressBarHeight = progressBarHeight
        self.minimumStatusLineHeight = minimumStatusLineHeight
        self.rowSpacing = rowSpacing
        self.groupBottomPadding = groupBottomPadding
        self.emptySectionHeight = emptySectionHeight
    }

    /// One status line: the step from a one-line row to a two-line row, at
    /// least `minimumStatusLineHeight`.
    public var statusLineHeight: CGFloat { max(rowHeightWithSubtitle - rowHeight, minimumStatusLineHeight) }

    /// The title line plus the status block: one `statusLineHeight` per
    /// status line and the progress bar.
    public func height(for ws: SidebarWorkspace) -> CGFloat {
        guard let status = ws.liveStatus else { return rowHeight }
        return rowHeight + CGFloat(status.lines.count) * statusLineHeight + (status.showsProgressBar ? progressBarHeight : 0)
    }
}

/// Inputs that change the layout besides the tree itself.
public nonisolated struct SidebarLayoutOptions: Hashable, Sendable {
    /// Workspaces removed from the layout (being dragged).
    public var excludedWorkspaces: Set<WorkspaceID> = []
    /// A group removed from the layout with its children (being dragged).
    public var excludedGroup: GroupID?
    /// When set, only these workspaces show; containers force-expand.
    public var filterMatches: Set<WorkspaceID>?
    /// Show the drop zone for an empty pinned section.
    public var showEmptyPinned = false
    /// Live gap to open, and its height.
    public var gap: DropPosition?
    public var gapHeight: CGFloat = 0
    /// Show the machine header even when only one machine is listed.
    /// Off by default: headers appear once a Cloud or SSH machine joins.
    public var showsSoleMachineHeader = false

    public init() {}
}
