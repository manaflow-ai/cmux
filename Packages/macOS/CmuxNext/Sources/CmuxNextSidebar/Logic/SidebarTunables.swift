public import CmuxNextDesign
public import CoreGraphics

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

    /// Sample rows with 1 to 7 pending items (`SidebarSection.rowBadgePreview()`).
    public static let rowBadgePreview = Tunable<Bool>.toggle(
        "sidebar.rowBadgePreview", .sidebar, "Row badge preview rows",
        help: "Adds sample rows with 1 to 7 pending items to the sidebar, to compare the row badges without real sessions.",
        default: false, code: "SidebarTunables.rowBadgePreview")

    /// The width transition used when the sidebar is collapsed or expanded.
    /// `.slide` is the shipped behavior; `.slideFade` is a DEV/NIGHTLY
    /// prototype for comparing a fast opacity fade against the same geometry.
    public static let collapseMotion = Tunable<SidebarCollapseMotionVariant>.choice(
        "sidebar.collapseMotion", .sidebar, "Sidebar collapse motion",
        help: "Prototype for hiding and showing the sidebar: slide keeps the panel opaque; slide and fade fades its content with the same width motion.",
        default: .slide, code: "SidebarTunables.collapseMotion")

    /// The transition used when a workspace row receives its generated or
    /// agent-derived title after creation. Crossfade is the shipped default (#21242).
    public static let workspaceTitleMotion = Tunable<SidebarWorkspaceTitleMotionVariant>.choice(
        "sidebar.workspaceTitleMotion", .sidebar, "Workspace title motion",
        help: "Prototype for a late workspace or agent-chat title: instant, crossfade, or a short upward lift in the existing title slot.",
        default: .instant, code: "SidebarTunables.workspaceTitleMotion")

    /// Every sidebar tunable, one per line in alphabetical order, so two pull requests that each add
    /// one insert different lines and merge cleanly (#21946). Debug Settings lists them in this order.
    public static var all: [TunableDescriptor] {
        [
            agentMark.descriptor,
            collapseMotion.descriptor,
            groupEdgeFraction.descriptor,
            groupExitFraction.descriptor,
            NotificationBadgeLook.tunable.descriptor,
            NotificationIconLook.tunable.descriptor,
            presenceDots.descriptor,
            rowBadgePreview.descriptor,
            sectionTopFraction.descriptor,
            SidebarChatsDesign.tunable.descriptor,
            SidebarRowBadgeStackCap.tunable.descriptor,
            SidebarRowBadgeStyle.tunable.descriptor,
            updateCardButton.descriptor,
            workspaceOntoEnd.descriptor,
            workspaceOntoStart.descriptor,
            workspaceTitleMotion.descriptor,
        ] + SidebarSectionTunables.all
    }
}
