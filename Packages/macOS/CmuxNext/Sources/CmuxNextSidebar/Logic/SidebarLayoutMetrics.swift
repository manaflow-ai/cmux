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
    /// A group or folder header: always the density's workspace row height (`rowStep`), never a
    /// number of its own (Lawrence 2026-10-19 and 2026-10-22: a header is exactly as tall as a
    /// workspace row at every density).
    public var groupHeaderHeight: CGFloat { rowStep }
    /// Expanded density (`sidebar.density` expanded, not Minimal Mode): every workspace row has a
    /// second line, so rows and group headers take two lines (`expanded`).
    public var twoLineRows = false
    /// The one height a group header and a workspace row with the density's usual lines share:
    /// one line, or two in Expanded. A row with more lines (a meta line, a status block) grows from it.
    public var rowStep: CGFloat { twoLineRows ? rowHeightWithSubtitle : rowHeight }
    /// Workspace row with one line.
    public var rowHeight: CGFloat
    /// Workspace row with a secondary detail line.
    public var rowHeightWithSubtitle: CGFloat
    public var tabRowHeight: CGFloat
    /// The one gap between consecutive rows: a group's last member, a folder's last row and the
    /// Pinned block's last row take it too, never a padding of their own (Leo 2026-10-21).
    public var rowSpacing: CGFloat
    public var emptySectionHeight: CGFloat
    /// One line of a row's status block (`WorkspaceRowContent.status`).
    public var statusLineHeight: CGFloat = 14
    /// The progress bar's slot in a status block.
    public var progressBarHeight: CGFloat = 8
    /// Below a status block, above the row's bottom edge.
    public var statusBottomPadding: CGFloat = 4

    public init(
        topPadding: CGFloat, bottomPadding: CGFloat, sectionHeaderHeight: CGFloat, sectionSpacing: CGFloat,
        rowHeight: CGFloat, rowHeightWithSubtitle: CGFloat, tabRowHeight: CGFloat, rowSpacing: CGFloat,
        emptySectionHeight: CGFloat
    ) {
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.sectionHeaderHeight = sectionHeaderHeight
        self.sectionSpacing = sectionSpacing
        self.rowHeight = rowHeight
        self.rowHeightWithSubtitle = rowHeightWithSubtitle
        self.tabRowHeight = tabRowHeight
        self.rowSpacing = rowSpacing
        self.emptySectionHeight = emptySectionHeight
    }

    /// Minimal mode's metrics (`sidebar.minimal`): shorter rows, tab rows and group headers (a
    /// header follows `rowHeight`). A group header keeps its solid bar in the group's color, only
    /// shorter (Lawrence 2026-10-18).
    public var minimal: SidebarLayoutMetrics {
        var m = self
        let step = (rowHeight * 0.17).rounded()
        m.rowHeight -= step
        m.rowHeightWithSubtitle -= step
        m.tabRowHeight -= step
        return m
    }

    /// Expanded density's metrics: rows and group headers are two lines tall (`rowStep`).
    public var expanded: SidebarLayoutMetrics {
        var m = self
        m.twoLineRows = true
        return m
    }

    /// The metrics a layout under `o` uses: Minimal Mode's shorter rows, or Expanded's two-line
    /// rows (not with workspaces as tabs, whose rows are one line at any density). Every place
    /// that sizes list rows reads this, so a header and a row cannot take different steps.
    public func resolved(for o: SidebarLayoutOptions) -> SidebarLayoutMetrics {
        if o.minimal { return minimal }
        return o.expanded && !o.workspacesAsTabs ? expanded : self
    }

    /// One line, two, or three (an expanded row's meta line adds one more line's height), never
    /// shorter than `rowStep`: in Expanded a row without a preview line keeps the two-line height.
    func height(for content: WorkspaceRowContent) -> CGFloat {
        let lines = (content.detail == nil ? 0 : 1) + (content.meta == nil ? 0 : 1)
        return max(rowStep, rowHeight + CGFloat(lines) * (rowHeightWithSubtitle - rowHeight)) + statusHeight(content)
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
    /// The machines whose rows carry their mark (SidebarMachineMark), when more than one is
    /// listed: the others, and this Mac with `sidebar.showLocalMachine`. Empty with one machine,
    /// where a mark would tell nothing.
    public var machines: [MachineID: SidebarMachine] = [:]
    /// Include tab rows beneath each visible workspace.
    public var showWorkspaceTabs = false
    /// With `showWorkspaceTabs`, the workspaces whose disclosure hid their tabs.
    public var collapsedWorkspaces: Set<WorkspaceID> = []
    /// Keep the active workspace visible beneath a collapsed group so the
    /// current destination remains anchored while the other members fold away.
    public var activeWorkspaceID: WorkspaceID?
    /// Members selected before that a collapsed group keeps drawing beside the active one (`SidebarModel.revealedMembers`).
    public var revealedWorkspaces: [GroupID: Set<WorkspaceID>] = [:]
    /// The workspaces collapsed group `id` draws as its visible members.
    func shown(inCollapsed id: GroupID) -> Set<WorkspaceID> { (revealedWorkspaces[id] ?? []).union(activeWorkspaceID.map { [$0] } ?? []) }
    /// What workspace rows show (`sidebar.workspaceRow.*`).
    public var workspaceRow = WorkspaceRowPreferences.defaults
    /// Minimal mode (`sidebar.minimal`): every row draws only its icon, name
    /// and marks, whatever `workspaceRow` shows (`rowContent`).
    public var minimal = false
    /// Expanded rows (`sidebar.density`), unless minimal: `WorkspaceRowContent(expanded:)`.
    public var expanded = false
    /// Workspaces as tabs (`SidebarTunables.workspacesAsTabs`): every workspace row is one line.
    public var workspacesAsTabs = false
    /// Row badges draw each state apart (`sidebar.detailedStatusIcons`), not Working or Ready only.
    public var detailedStatus = false
    /// Rows show when they last changed (`sidebar.showTimestamps`): an expanded row's age and a
    /// compact row's dim time on the name's line. Off by default (Lawrence 2026-10-19): no row
    /// draws a time unless the user picks the Last Activity element.
    public var showsTimestamps = false
    /// `sidebar.showColors`: off, a row draws no workspace color (`WorkspaceIcon.uncolored`).
    public var showsColors = true
    /// `workspaceColors.indicatorStyle`: a colored row's dot, leading rail or full-row fill (#25653).
    public var colorIndicator: WorkspaceColorIndicatorStyle = .dot
    /// The start of today: the last-activity element shows a time for today,
    /// else a date. A day, not the current time, so options stay equal.
    public var now = Date(timeIntervalSince1970: 0)
    /// Age labels this pass made, shared by its rows (a label per row was most of a 10k group's layout).
    var ages = AgeTextCache()
    /// The workspace list is hidden (`sidebar.showProjects` off): no rows.
    public var hidesWorkspaces = false
    /// `sidebar.groupBy`. Group by Folder: the only machine's loose rows sit under a header per
    /// `SidebarWorkspace.folder`, in first-seen order. Group by Status: `SidebarLayout+Status`.
    public var grouping = SidebarGrouping()
    /// `sidebar.sessionTree`: a workspace started by another's agent lists under it, and rows
    /// carry their pull requests and keycaps. Nil (off) draws the list as before.
    public var sessionTree: SidebarSessionTreeState?
    /// Each row's pull request badge (`sidebar.pullRequestBadges`), drawn with the tree off too.
    public var pullRequests: [WorkspaceID: SidebarPullRequestBadge] = [:]
    /// The session tree's keycaps: each workspace's Command-number (`SidebarItemOrder`).
    public var keycaps: [WorkspaceID: Int] = [:]
    /// The session tree's chat history (`SidebarChatHistoryState`): Pinned above the workspaces,
    /// Earlier under them. Nil (the tree off, or a filter) draws neither.
    public var chatHistory: SidebarChatHistoryState?
    /// `sidebar.doneFold`: workspaces marked Done fold into a "Done (N)" row at the end of their list.
    public var foldsDone = false
    /// The "Done (N)" rows the person opened: their workspaces list below them.
    public var openDoneFolds: Set<SidebarDoneFoldID> = []
    /// `sidebar.groupRowLimit`: a list longer than this shows its first rows and a "Show N more" row; 0 shows all.
    public var rowLimit = 0
    /// The lists whose "Show N more" row the person opened.
    public var openShowMore: Set<SidebarDoneFoldID> = []

    public init() {}
}

nonisolated extension SidebarLayoutOptions {
    /// Icon, the working spinner and progress (spinner and OSC 9;4 bar, Lawrence via cx-htbe5): the name
    /// and the unread mark always draw (minimal mode).
    static let minimalRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: [.icon, .working, .progress]))
    /// Workspaces as tabs: the icon, the working spinner and the pull request badge, on the name's
    /// line with the status glyph and the unread mark (Claude desktop's chat list).
    static let tabRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: [.icon, .working, .pullRequest]))

    /// What `ws`'s row draws under these options. Minimal mode drops the
    /// second line (including another computer's name and a machine's
    /// stage), the status block, counts and badges; the working spinner,
    /// loading, the progress bar and attention states still show, like the unread mark.
    func rowContent(_ ws: SidebarWorkspace, machine: String?) -> WorkspaceRowContent {
        var content = baseRowContent(ws, machine: machine)
        content.detailedStatus = detailedStatus
        content.machine = machines[ws.machineID].map(SidebarMachineMark.init)
        if let sessionTree { content.keycap = keycaps[ws.id] }
        // Leo 2026-10-21, "REMOVE PR INDICATORS BY DEFAULT": every pull request mark on a row (the
        // hook's text and the read badge, tree or not) follows `sidebar.workspaceRow.pullRequest`,
        // off by default. The hover card keeps the pull request.
        if workspaceRow.resolved(for: ws.rowKind).shows(.pullRequest) {
            content.pullRequests = sessionTree?.pullRequests[ws.id] ?? pullRequests[ws.id]
        } else {
            content.badge = nil
        }
        if !showsTimestamps { (content.time, content.badgeTime) = (nil, nil) }
        if !showsColors {
            content.icon = content.icon?.uncolored
        } else if colorIndicator != .dot, let color = ws.color ?? ws.icon?.color {
            // The rail or the fill says the color, so a bare swatch would say it twice; a symbol or emoji stays.
            (content.rowColor, content.colorStyle) = (color, colorIndicator)
            if case .swatch? = content.icon { content.icon = nil }
        }
        // What the agent needs, for the row's accessibility label only: a row draws no status words
        // (Leo 2026-10-21), its badge's dot says it. Worded on the main actor by the row view.
        if !minimal, let chip = WorkspaceRowContent.rowChip(ws.agentChip) { content.chip = chip }
        // A row that already has a second line says there what its agent does now; a one-line row
        // keeps its height, so rows do not grow and shrink as agents start and stop.
        if !minimal, content.detail != nil, let step = ws.agentStep { (content.now, content.detail) = (step, step) }
        return content
    }

    private func baseRowContent(_ ws: SidebarWorkspace, machine: String?) -> WorkspaceRowContent {
        // Workspaces as tabs: one line at any density; attention states (the needs-you mark) still show.
        if workspacesAsTabs {
            var content = WorkspaceRowContent(ws, preferences: Self.tabRow, now: now, ages: ages)
            (content.detail, content.status, content.trailingStatus, content.badgeTime) = (nil, nil, nil, nil)
            return content
        }
        if expanded && !minimal {
            let shown = workspaceRow.resolved(for: ws.rowKind)
            return WorkspaceRowContent(expanded: ws, now: now, machine: machine, showsNotification: shown.shows(.notification),
                                       showsPullRequest: shown.shows(.pullRequest), ages: ages)
        }
        guard minimal else { return WorkspaceRowContent(ws, preferences: workspaceRow, now: now, machine: machine, ages: ages) }
        var content = WorkspaceRowContent(ws, preferences: Self.minimalRow, now: now, ages: ages)
        content.detail = nil
        content.badgeTime = nil
        content.status = nil
        return content
    }
}

nonisolated extension SidebarLayoutOptions {
    /// Whether the list draws workspace `ws`: not dragged out, and a match while filtering.
    func visible(_ ws: SidebarWorkspace) -> Bool {
        !excludedWorkspaces.contains(ws.id) && (filterMatches?.contains(ws.id) ?? true)
    }

    /// `showWorkspaceTabs` lists every workspace's tabs, except those the user collapsed with the row's disclosure.
    func listsTabs(_ ws: SidebarWorkspace) -> Bool {
        showWorkspaceTabs && !collapsedWorkspaces.contains(ws.id)
    }

    /// A workspace row's tab disclosure; nil when the list shows no tabs.
    func disclosure(_ ws: SidebarWorkspace) -> SidebarTabDisclosure? {
        guard showWorkspaceTabs else { return nil }
        if ws.tabs.isEmpty { return .empty }
        return collapsedWorkspaces.contains(ws.id) ? .collapsed : .expanded
    }
}
