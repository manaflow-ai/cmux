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
    /// One line of a row's status block (`WorkspaceRowContent.status`).
    public var statusLineHeight: CGFloat = 14
    /// The progress bar's slot in a status block.
    public var progressBarHeight: CGFloat = 8
    /// Below a status block, above the row's bottom edge.
    public var statusBottomPadding: CGFloat = 4

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

    /// Minimal mode's metrics (`sidebar.minimal`): shorter rows, tab rows and group headers. A
    /// group header keeps its solid bar in the group's color, only shorter (Lawrence 2026-10-18).
    public var minimal: SidebarLayoutMetrics {
        var m = self
        let step = (rowHeight * 0.17).rounded()
        m.rowHeight -= step
        m.rowHeightWithSubtitle -= step
        m.tabRowHeight -= step
        m.groupHeaderHeight = m.rowHeight
        return m
    }

    /// One line, two, or three (an expanded row's meta line adds one more line's height).
    func height(for content: WorkspaceRowContent) -> CGFloat {
        let lines = (content.detail == nil ? 0 : 1) + (content.meta == nil ? 0 : 1)
        return rowHeight + CGFloat(lines) * (rowHeightWithSubtitle - rowHeight) + statusHeight(content)
    }

    /// The status block under the title lines: its text lines, the bar's
    /// slot when the row has progress, and a bottom padding; 0 without one.
    public func statusHeight(_ content: WorkspaceRowContent) -> CGFloat {
        guard let status = content.status else { return 0 }
        return CGFloat(status.lines.count) * statusLineHeight + (content.progress == nil ? 0 : progressBarHeight) + statusBottomPadding
    }
}

/// Inputs that change the layout besides the tree itself.
public nonisolated struct SidebarLayoutOptions: Hashable, Sendable {
    /// Workspaces removed from the layout (being dragged).
    public var excludedWorkspaces: Set<WorkspaceID> = []
    /// A group removed from the layout with its children (being dragged).
    public var excludedGroup: GroupID?
    /// A listed document item removed from the layout (being dragged).
    public var excludedItem: String?
    /// The height of each document section's block (its items in its own arrangement), by section id.
    public var blockHeights: [String: CGFloat] = [:]
    /// Document sections folded by their header: their groups do not list.
    public var collapsedDocSections: Set<String> = []
    /// Document sections whose block draws no item (at most a title): during a drag (`showEmptyPinned`)
    /// each opens a one-row drop zone under its title, so an empty section always takes a drop.
    public var emptyDocSections: Set<String> = []
    /// When set, only these workspaces show; containers force-expand.
    public var filterMatches: Set<WorkspaceID>?
    /// Show the drop zone for an empty pinned section.
    public var showEmptyPinned = false
    /// Live gap to open, and its height.
    public var gap: DropPosition?
    public var gapHeight: CGFloat = 0
    /// With `sidebar.groupByComputer`, show the machine header even when
    /// only one machine is listed, titled "Projects" (the sidebar list sets
    /// it). One list (the default) never shows it (cx-mdo0).
    public var showsSoleMachineHeader = false
    /// One workspace list (`sidebar.groupByComputer` off): machine sections
    /// show no header and no gap between them, and a row of a computer other
    /// than this Mac names it (and a failed connection) on its second line.
    public var flattensMachines = false
    /// In one list, the status a computer's rows name after its name when it
    /// cannot connect until the person acts ("Failed to start"; cx-mdo0).
    /// Localized by the model, so the layout stays nonisolated.
    public var machineStatusLabels: [MachineID: String] = [:]
    /// Include tab rows beneath each visible workspace.
    public var showWorkspaceTabs = false
    /// With `showWorkspaceTabs`, the workspaces whose disclosure hid their tabs.
    public var collapsedWorkspaces: Set<WorkspaceID> = []
    /// Keep the active workspace visible beneath a collapsed group so the
    /// current destination remains anchored while the other members fold away.
    public var activeWorkspaceID: WorkspaceID?
    /// What workspace rows show (`sidebar.workspaceRow.*`).
    public var workspaceRow = WorkspaceRowPreferences.defaults
    /// Minimal mode (`sidebar.minimal`): every row draws only its icon, name
    /// and marks, whatever `workspaceRow` shows (`rowContent`).
    public var minimal = false
    /// Expanded rows (`sidebar.density`), unless minimal: `WorkspaceRowContent(expanded:)`.
    public var expanded = false
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

nonisolated extension SidebarLayoutOptions {
    /// Icon, the working spinner and progress (spinner and OSC 9;4 bar, Lawrence via cx-htbe5): the name
    /// and the unread mark always draw (minimal mode).
    static let minimalRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: [.icon, .working, .progress]))

    /// What `ws`'s row draws under these options. Minimal mode drops the
    /// second line (including another computer's name and a machine's
    /// stage), the status block, counts and badges; the working spinner,
    /// loading, the progress bar and attention states still show, like the unread mark.
    func rowContent(_ ws: SidebarWorkspace, machine: String?) -> WorkspaceRowContent {
        if expanded && !minimal {
            return WorkspaceRowContent(expanded: ws, now: now, machine: machine,
                                       showsNotification: workspaceRow.resolved(for: ws.rowKind).shows(.notification))
        }
        guard minimal else { return WorkspaceRowContent(ws, preferences: workspaceRow, now: now, machine: machine) }
        var content = WorkspaceRowContent(ws, preferences: Self.minimalRow, now: now)
        content.detail = nil
        content.badgeTime = nil
        content.status = nil
        return content
    }
}
