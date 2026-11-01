public import CmuxNextDesign
public import CoreGraphics

/// How a machine's group shows its room (`sidebar.remoteMachines.resources`): free RAM, cores
/// busy and free disk, from the reading acpmux's link keeps (Leo 2026-10-24: "how much RAM do you
/// have before you start ... how much CPU utilization").
public nonisolated enum RemoteMachineResourcesStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// An unfolded group's first row: "31 GB free · CPU 12/32" (free disk too when it is low).
    case row
    /// The header after the name: "huge-blue · 31 GB free", folded or not.
    case header
    /// Neither.
    case off

    public var tunableTitle: String {
        switch self {
        case .row: "Row under the machine (unfolded)"
        case .header: "Free RAM after the machine's name"
        case .off: "Off"
        }
    }
}

/// Prototype variants for the sidebar's width transition (Debug Settings
/// `sidebar.collapseMotion`). The default keeps the existing slide-only
/// behavior; the fade variant is opt-in so the two looks can be compared
/// without changing a user's normal configuration.
public nonisolated enum SidebarCollapseMotionVariant: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The current sidebar transition: the panel stays opaque while its clip
    /// width moves to (or from) zero.
    case slide
    /// The panel's content fades with the width transition, keeping the
    /// geometry unchanged while avoiding a hard edge at the end of a hide.
    case slideFade

    public var tunableTitle: String {
        switch self {
        case .slide: "Slide"
        case .slideFade: "Slide and fade"
        }
    }

    var fadesPanel: Bool { self == .slideFade }
}

/// Prototype variants for a workspace's generated/display title changing after
/// a new tab or agent chat becomes identifiable (`sidebar.workspaceTitleMotion`).
/// The title keeps its measured slot in every variant, so a late name never
/// causes a row reflow or a one-frame blank replacement.
public nonisolated enum SidebarWorkspaceTitleMotionVariant: String, Sendable, CaseIterable, Hashable, TunableChoice {
    case instant
    case crossfade
    case lift

    public var tunableTitle: String {
        switch self {
        case .instant: "Instant"
        case .crossfade: "Crossfade"
        case .lift: "Lift"
        }
    }
}

/// Debug Settings tunables of sidebar drag and drop (`DropResolver`).
/// Sidebar sizes come from `Metrics` (`MetricTunables`).
public nonisolated enum SidebarTunables {
    public static let groupEdgeFraction = Tunable<CGFloat>.number(
        "sidebar.drop.groupEdgeFraction", .sidebar, "Group header edge share",
        help: "Share of a collapsed group header, from each edge, that drops before or after the group instead of into it.",
        default: 0.25, range: 0...0.5, step: 0.01, unit: .fraction, code: "SidebarTunables.groupEdgeFraction")
    public static let groupExitFraction = Tunable<CGFloat>.number(
        "sidebar.drop.groupExitFraction", .sidebar, "Group exit share",
        help: "Lower share of a group's last row that drops after the group.",
        default: 0.25, range: 0...0.5, step: 0.01, unit: .fraction, code: "SidebarTunables.groupExitFraction")
    public static let sectionTopFraction = Tunable<CGFloat>.number(
        "sidebar.drop.sectionTopFraction", .sidebar, "Section header top share",
        help: "Upper share of a section header that drops at the end of the previous section.",
        default: 0.35, range: 0...0.8, step: 0.01, unit: .fraction, code: "SidebarTunables.sectionTopFraction")
    public static let workspaceOntoStart = Tunable<CGFloat>.number(
        "sidebar.drop.workspaceOntoStart", .sidebar, "Group-on-drop band start",
        help: "Where the middle band of a loose workspace row starts; a drop in the band groups the two workspaces.",
        default: 0.3, range: 0...0.5, step: 0.01, unit: .fraction, code: "SidebarTunables.workspaceOntoStart")
    public static let workspaceOntoEnd = Tunable<CGFloat>.number(
        "sidebar.drop.workspaceOntoEnd", .sidebar, "Group-on-drop band end",
        help: "Where the middle band of a loose workspace row ends. Equal to the start turns grouping on drop off.",
        default: 0.7, range: 0.5...1, step: 0.01, unit: .fraction, code: "SidebarTunables.workspaceOntoEnd")

    /// How far a press moves before it drags (`SidebarPress.dragThreshold`; Leo 2026-10-20: a click never drags).
    public static let dragThreshold = Tunable<CGFloat>.number(
        "sidebar.drag.threshold", .sidebar, "Drag start distance",
        help: "How far a press on a sidebar row or tile moves before it drags; a shorter move stays a click.",
        default: 6, range: 2...16, step: 0.5, unit: .points, code: "SidebarTunables.dragThreshold")

    public static let agentMark = Tunable<SidebarAgentMarkVariant>.choice(
        "sidebar.agentMark", .sidebar, "Agent mark",
        help: "Where a workspace row draws the brand mark of an agent running in it (R79 prototype).",
        default: .off, code: "SidebarTunables.agentMark")

    /// Multiplayer agent presence (cx-gg84): off until the dots are styled
    /// into the row; the daemon feed (`agent-presence-v1`) runs either way.
    public static let presenceDots = Tunable<Bool>.toggle(
        "sidebar.presenceDots", .sidebar, "Agent presence dots",
        help: "A round dot per agent acting right now, in the agent's theme color: on its workspace row (hover lists what each one touches) and on its tab chip (prototype).",
        default: false, code: "SidebarTunables.presenceDots")

    /// Rows show their agent sessions' acpmux lane state (`SidebarLaneStatus`): working, waiting
    /// on you, failed, idle, even when no turn state reached the row. Off by default (Lawrence 2026-10-21).
    public static let laneStatus = Tunable<Bool>.toggle(
        "sidebar.laneStatus", .sidebar, "Rows show acpmux lane status",
        help: "A workspace row's status mark also follows the acpmux lane of each agent chat in it on this Mac: waiting on you or failed wins, then working, then the row's own status.",
        default: false, code: "SidebarTunables.laneStatus")

    /// A row's accessibility label names the state of its most urgent agent chat with the Priority
    /// view's words (needs you, failed, lost; never Done, `WorkspaceRowContent.rowChip`;
    /// `SidebarLaneStatus`). The row draws no status words: its badge's dot says it (Leo 2026-10-21).
    /// Off by default (Lawrence 2026-10-21).
    public static let rowStatus = Tunable<Bool>.toggle(
        "sidebar.rowStatus", .sidebar, "Row labels name their agent's state",
        help: "A workspace row's accessibility label says needs you, failed or lost, in the Priority view's words, for the most urgent agent chat in it on this Mac. The row itself draws no status words; its badge's dot says it.",
        default: false, code: "SidebarTunables.rowStatus")

    /// Group by Status (Leo 2026-10-14, #20905): the list's rows under the Priority view's states, from the state each
    /// row already carries from the Priority classifier, in manual order inside each (`SidebarLayout+Status`). Off by
    /// default; it wins over Group Projects By while on.
    public static let groupByStatus = Tunable<Bool>.toggle(
        "sidebar.groupByStatus", .sidebar, "Group by status",
        help: "Lists every computer's rows under the Priority view's states (Needs you, Done, Failed, CI failing, Working, Idle) with counts, in your order inside each. Rows move as their state changes; the active row stays put until another row is active.",
        default: false, code: "SidebarTunables.groupByStatus")

    /// Workspaces marked Done fold into one "Done (N)" row at the end of their group or list (`SidebarLayout+DoneFold`).
    public static let doneFold = Tunable<Bool>.toggle(
        "sidebar.doneFold", .sidebar, "Fold Done workspaces",
        help: "Workspaces marked Done move into one Done row at the end of their group or list, in their order; click the row to show them.",
        default: true, code: "SidebarTunables.doneFold")

    /// A group or list longer than this shows its first rows, the ones that need you and the active one, then a
    /// "Show N more" row (`SidebarLayout+DoneFold`). 0, the default for now, shows every row.
    public static let groupRowLimit = Tunable<Double>.number(
        "sidebar.groupRowLimit", .sidebar, "Rows before Show more",
        help: "A group or list longer than this shows its first rows, the ones that need you and the active one, then a Show more row. 0 shows every row.",
        default: 0, range: 0...100, step: 1, unit: .count, code: "SidebarTunables.groupRowLimit")
    /// `groupRowLimit` as a row count.
    public static var rowLimit: Int { max(0, Int(groupRowLimit.value)) }

    /// The workspace hover card says what its agents did since the person last looked at it
    /// (`SidebarLookedStore`): turns done, questions, failures. On by default.
    public static let sinceLooked = Tunable<Bool>.toggle(
        "sidebar.sinceLooked", .sidebar, "Since you looked",
        help: "A workspace's hover card counts the turns its agents finished, the questions they asked and the turns that failed since you last had it open.",
        default: true, code: "SidebarTunables.sinceLooked")

    /// A working row's second line says what its agent does right now (`SidebarLaneStatus`). Off
    /// by default (Lawrence 2026-10-21); a row without a second line keeps its one line (the hover card says it).
    public static let nowLine = Tunable<Bool>.toggle(
        "sidebar.nowLine", .sidebar, "Rows say what their agent does now",
        help: "While an agent chat in a workspace works, the row's second line reads \"Now:\" and what the agent is doing. A one-line row stays one line.",
        default: false, code: "SidebarTunables.nowLine")

    /// Sample agent lanes on every row (`SidebarLaneFixture`), for captures on a slot with no agents.
    public static let laneFixture = Tunable<Bool>.toggle(
        "sidebar.laneFixture", .sidebar, "Sample agent states on rows",
        help: "Gives every workspace row a sample agent chat (needs you, working, done, failed or idle), to see the row states without real sessions.",
        default: false, code: "SidebarTunables.laneFixture")

    /// How a remote machine's group shows its free RAM, cores busy and free disk (`RemoteMachinesSidebar`).
    public static let remoteMachineResources = Tunable<RemoteMachineResourcesStyle>.choice(
        "sidebar.remoteMachines.resources", .sidebar, "Remote machines' room",
        help: "How a machine's group shows its free RAM, cores busy and free disk, from the reading acpmux takes every minute.",
        default: .row, code: "SidebarTunables.remoteMachineResources")

    /// Every row carries its pull requests' badge, with or without the session tree
    /// (`SidebarSessionTreeFeed`), while the row's Pull Request element is on
    /// (`sidebar.workspaceRow.pullRequest`, off by default). On by default; the tree's nesting and keycaps stay opt-in.
    public static let pullRequestBadges = Tunable<Bool>.toggle(
        "sidebar.pullRequestBadges", .sidebar,
        String(localized: "sidebar.pullRequestBadges.label", defaultValue: "Rows show their pull requests", bundle: .module),
        help: String(localized: "sidebar.pullRequestBadges.help", defaultValue: "A workspace row shows a badge for the pull requests its agent chats opened or its folder's branch has, quiet unless their checks fail, even with the session tree off.", bundle: .module),
        default: true, code: "SidebarTunables.pullRequestBadges")

    /// The pull requests' hover card on a row's pull request badge (`SidebarPullRequestCard`,
    /// `sidebar.sessionTree`); on by default.
    public static let pullRequestCard = Tunable<Bool>.toggle(
        "sidebar.pullRequestCard", .sidebar, "Pull request hover card",
        help: "Hovering a row's pull request badge lists each pull request with its state, repository and size; a click opens it.",
        default: true, code: "SidebarTunables.pullRequestCard")

    /// Leo 2026-10-21 (item D, multi-view): a press on a workspace row selects nothing; the click
    /// (mouse-up on the same row) navigates, and a hold-then-drag moves the row without leaving the
    /// workspace on screen. Rows of every workspace on screen draw a soft fill (`SidebarModel.onScreen`). A row dropped
    /// on a pane edge shows its workspace beside the shown one (the App's `WindowController.placeBeside`).
    public static let multiView = Tunable<Bool>.toggle(
        "sidebar.multiView", .sidebar, "Navigate on release (multi-view prototype)",
        help: "A press on a workspace row changes nothing until the button comes up on that row; holding and dragging moves the row without switching to it. A row dropped on a pane edge shows its workspace beside the shown one. Rows of every workspace on screen get a soft highlight.",
        default: false, code: "SidebarTunables.multiView")

    /// A workspace nobody named whose name says nothing ("workspace-11", "~") reads in the
    /// secondary ink while idle, read and not selected (Leo 2026-10-20: such rows clutter the
    /// sidebar). On by default; off draws every name in the full ink.
    public static let quietUnnamedRows = Tunable<Bool>.toggle(
        "sidebar.quietUnnamedRows", .sidebar, "Quiet unnamed workspaces",
        help: "An idle workspace nobody named (workspace-11, ~) shows its name dimmed until it has activity, something unread or the selection.",
        default: true, code: "SidebarTunables.quietUnnamedRows")

    /// What a workspace row's name says: the workspace (the default), a breadcrumb to its focused
    /// tab, the focused tab alone, or every tab (Leo 2026-10-26, `SidebarRowTitleMode`).
    public static let rowTitle = Tunable<SidebarRowTitleMode>.choice(
        "sidebar.rowTitle", .sidebar, "Workspace row name",
        help: "What a workspace row's name says: the workspace alone, the workspace then its focused tab (Workspace › Tab), the focused tab alone (the hover card names the workspace), or the workspace then all its tabs, cut off at the row's end.",
        default: .workspace, code: "SidebarTunables.rowTitle")

    /// A workspace whose one tab is an agent chat shows the chat's name alone, whatever
    /// `rowTitle` says (Leo 2026-10-26). Off by default.
    public static let rowTitleSingleChat = Tunable<Bool>.toggle(
        "sidebar.rowTitleSingleChat", .sidebar, "Single chat names its workspace",
        help: "A workspace whose only tab is an agent chat shows the chat's name on its row instead of the workspace's.",
        default: false, code: "SidebarTunables.rowTitleSingleChat")

    /// Sample rows for each workspace row name (`SidebarSection.rowTitlePreview()`).
    public static let rowTitlePreview = Tunable<Bool>.toggle(
        "sidebar.rowTitlePreview", .sidebar, "Row name preview rows",
        help: "Adds sample workspaces with several tabs to the sidebar, to compare the workspace row names without real sessions.",
        default: false, code: "SidebarTunables.rowTitlePreview")

    /// Sample rows with 1 to 7 pending items (`SidebarSection.rowBadgePreview()`).
    public static let rowBadgePreview = Tunable<Bool>.toggle(
        "sidebar.rowBadgePreview", .sidebar, "Row badge preview rows",
        help: "Adds sample rows with 1 to 7 pending items to the sidebar, to compare the row badges without real sessions.",
        default: false, code: "SidebarTunables.rowBadgePreview")

    /// A detail line adds exactly its own height to a row, so one-line and two-line rows keep the
    /// same room above and below their text (Leo 2026-10-20). Off: the app's fixed 12 pt step.
    public static let evenRowText = Tunable<Bool>.toggle(
        "sidebar.evenRowText", .sidebar, "Even row text spacing",
        help: "A row's detail line adds its own height, so rows with one line and rows with two keep the same space above and below their text.",
        default: true, code: "SidebarTunables.evenRowText")

    /// The width transition used when the sidebar is collapsed or expanded.
    /// `.slide` is the shipped behavior; `.slideFade` is a DEV/NIGHTLY
    /// prototype for comparing a fast opacity fade against the same geometry.
    public static let collapseMotion = Tunable<SidebarCollapseMotionVariant>.choice(
        "sidebar.collapseMotion", .sidebar, "Sidebar collapse motion",
        help: "Prototype for hiding and showing the sidebar: slide keeps the panel opaque; slide and fade fades its content with the same width motion.",
        default: .slide, code: "SidebarTunables.collapseMotion")

    // @intent Leo 2026-10-31: the sidebar toggle must not snap after it settles.
    // Holding a wider content frame needs a second resize at landing; keep that optimization
    // available for comparison, but normally let content follow the sidebar edge.
    /// Whether the content beside the sidebar keeps one width through a show or hide slide.
    public static let slideHoldsContent = Tunable<Bool>.toggle(
        "sidebar.slideHoldsContent", .sidebar, "Hold content size in sidebar slide",
        help: "While the sidebar slides open or closed, the panes beside it take their final width when the slide starts and stay still, pinned to the far edge, while the sidebar slides over the near one. Off: every pane resizes on every frame.",
        default: false, code: "SidebarTunables.slideHoldsContent")

    /// The transition used when a workspace row receives its generated or
    /// agent-derived title after creation. Crossfade is the shipped default (#21242).
    public static let workspaceTitleMotion = Tunable<SidebarWorkspaceTitleMotionVariant>.choice(
        "sidebar.workspaceTitleMotion", .sidebar, "Workspace title motion",
        help: "Prototype for a late workspace or agent-chat title: instant, crossfade, or a short upward lift in the existing title slot.",
        default: .instant, code: "SidebarTunables.workspaceTitleMotion")

    /// Where a hovered workspace row's ✕ sits (`SidebarRowCloseSpot`); at the row's end by default.
    public static let rowCloseSpot = Tunable<SidebarRowCloseSpot>.choice(
        "sidebar.rowCloseSpot", .sidebar, "Workspace row close position",
        help: "Where a hovered workspace row's close button sits: at the row's end in place of the status mark (menu, chevron, close), with even gaps, a smaller close, or between the menu and the chevron as before.",
        default: .end, code: "SidebarTunables.rowCloseSpot")

    /// "Workspaces as tabs" (Leo, relayed 2026-10-21; prototype, off): every workspace row is one
    /// line (its icon, name, status and pull request badge, as Claude desktop's chat list), and
    /// Cmd-Shift-[ / ] step the workspaces in sidebar order as tabs (`nextSidebarTab`), wrapping,
    /// across groups, everywhere but Home. Off, Cmd-Shift-[ / ] cycle a pane's tabs as they ship
    /// (Lawrence 2026-10-15), so the default keymap does not change.
    public static let workspacesAsTabs = Tunable<Bool>.toggle(
        "sidebar.workspacesAsTabs", .sidebar, "Workspaces as tabs",
        help: "Workspace rows are one line (name, status, pull request), and Cmd-Shift-[ / ] go to the previous or next workspace, wrapping, instead of the previous or next tab (Home keeps its own keys).",
        default: false, code: "SidebarTunables.workspacesAsTabs")

    /// Dogfood the connected group chip and capped rail without changing the shipped look.
    public static let groupChromeShape = Tunable<Bool>.toggle(
        "sidebar.groupChromeShape", .sidebar, "Connected group chip and rail",
        help: "Prototype a group-colored header joined to a thicker rail with a clipped join and rounded end. Collapsed groups show only the header. Applies to the solid band look.",
        default: false, code: "SidebarTunables.groupChromeShape")

    /// Every sidebar tunable, one per line in alphabetical order, so two pull requests that each add
    /// one insert different lines and merge cleanly (#21946). Debug Settings lists them in this order.
    public static var all: [TunableDescriptor] {
        [
            agentMark.descriptor,
            collapseMotion.descriptor,
            doneFold.descriptor,
            dragThreshold.descriptor,
            evenRowText.descriptor,
            groupByStatus.descriptor,
            groupChromeShape.descriptor,
            groupEdgeFraction.descriptor,
            groupExitFraction.descriptor,
            groupRowLimit.descriptor,
            laneStatus.descriptor,
            rowStatus.descriptor,
            pullRequestBadges.descriptor,
            laneFixture.descriptor,
            remoteMachineResources.descriptor,
            sinceLooked.descriptor,
            slideHoldsContent.descriptor,
            nowLine.descriptor,
            multiView.descriptor,
            NotificationBadgeLook.tunable.descriptor,
            NotificationIconLook.tunable.descriptor,
            presenceDots.descriptor,
            quietUnnamedRows.descriptor,
            pullRequestCard.descriptor,
            rowBadgePreview.descriptor,
            rowCloseSpot.descriptor,
            rowTitle.descriptor,
            rowTitlePreview.descriptor,
            rowTitleSingleChat.descriptor,
            sectionTopFraction.descriptor,
            SidebarChatsDesign.tunable.descriptor,
            SidebarGroupHeaderStyle.tunable.descriptor,
            SpaceSwitcherStyle.tunable.descriptor,
            SidebarGroupPalette.tunable.descriptor,
            SidebarGroupLineLayout.tunable.descriptor,
            SidebarInsertMotion.nudgeDistance.descriptor,
            SidebarInsertMotion.tunable.descriptor,
            SidebarRowBadgeStackCap.tunable.descriptor,
            SidebarRowBadgeStyle.tunable.descriptor,
            simulatePendingUpdate.descriptor,
            updateCardAutomaticControl.descriptor,
            updateCardButton.descriptor,
            workspaceOntoEnd.descriptor,
            workspaceOntoStart.descriptor,
            workspacesAsTabs.descriptor,
            workspaceTitleMotion.descriptor,
        ] + SidebarSectionTunables.all
    }
}
