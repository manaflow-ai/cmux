public import CmuxNextDesign
public import CoreGraphics
public import Foundation

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
    /// Workspace row with a secondary detail line.
    public var rowHeightWithSubtitle: CGFloat
    public var tabRowHeight: CGFloat
    public var rowSpacing: CGFloat
    public var groupBottomPadding: CGFloat
    public var emptySectionHeight: CGFloat

    public init(
        topPadding: CGFloat, bottomPadding: CGFloat, sectionHeaderHeight: CGFloat, sectionSpacing: CGFloat,
        groupHeaderHeight: CGFloat, rowHeight: CGFloat, rowHeightWithSubtitle: CGFloat, tabRowHeight: CGFloat, rowSpacing: CGFloat,
        groupBottomPadding: CGFloat, emptySectionHeight: CGFloat
    ) {
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.sectionHeaderHeight = sectionHeaderHeight
        self.sectionSpacing = sectionSpacing
        self.groupHeaderHeight = groupHeaderHeight
        self.rowHeight = rowHeight
        self.rowHeightWithSubtitle = rowHeightWithSubtitle
        self.tabRowHeight = tabRowHeight
        self.rowSpacing = rowSpacing
        self.groupBottomPadding = groupBottomPadding
        self.emptySectionHeight = emptySectionHeight
    }

    func height(for content: WorkspaceRowContent) -> CGFloat {
        content.detail == nil ? rowHeight : rowHeightWithSubtitle
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
    /// Show the machine header even when only one machine is listed,
    /// titled "Projects" (the sidebar list sets it). Off in bare layouts.
    public var showsSoleMachineHeader = false
    /// One workspace list (`sidebar.groupByComputer` off): machine sections
    /// show no header and no gap between them, and a row of a computer other
    /// than this Mac names it on its second line.
    public var flattensMachines = false
    /// Include tab rows beneath each visible workspace.
    public var showWorkspaceTabs = false
    /// With `showWorkspaceTabs`, the workspaces whose disclosure hid their tabs.
    public var collapsedWorkspaces: Set<WorkspaceID> = []
    /// What workspace rows show (`sidebar.workspaceRow.*`).
    public var workspaceRow = WorkspaceRowPreferences.defaults
    /// The start of today: the last-activity element shows a time for today,
    /// else a date. A day, not the current time, so options stay equal.
    public var now = Date(timeIntervalSince1970: 0)
    /// The workspace list is hidden (`sidebar.showProjects` off): no rows.
    public var hidesWorkspaces = false
    /// Group by Folder (`sidebar.groupBy`): the only machine's loose rows
    /// sit under a header per `SidebarWorkspace.folder`, in first-seen order.
    public var groupsByFolder = false

    public init() {}
}
