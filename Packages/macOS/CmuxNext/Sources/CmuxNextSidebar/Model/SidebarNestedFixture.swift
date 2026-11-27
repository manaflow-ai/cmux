#if DEBUG
import CmuxNextDesign
import Foundation

/// The nested-groups prototype's capture fixtures: real sidebar sections with groups inside
/// groups, for `debug.sidebar_nested_fixture` and the layout tests.
///
/// ```swift
/// let fixture = SidebarNestedFixture(scenario: .deep)
/// model.setSections(fixture.sections)
/// ```
public nonisolated struct SidebarNestedFixture: Sendable {
    /// One captured state.
    public enum Scenario: String, CaseIterable, Sendable {
        /// The user's sidebar of 2026-10-21: Perf stored inside Panes & layout, drawn with the old rails.
        case before
        /// The same tree with the prototype's rails: Perf reads as Panes & layout's subgroup.
        case after
        /// Two levels: groups with subgroups, all open.
        case depth2
        /// Six levels deep, all open.
        case deep
        /// The six-level tree with folded levels: unread and loading roll up to each folded header.
        case collapsed
        /// A drag over a group's header middle: the drop goes inside it.
        case dragInto
        /// A drag at a nested block's bottom edge, pointer to the left: the drop goes out to a parent level.
        case dragOut
        /// The six-level tree in a narrow sidebar: the indent stops at the cap, labels keep their width.
        case narrow
        /// A tall group (ten members) among short groups and loose rows, for group drag captures
        /// (`debug.sidebar_group_drag`; Lawrence 2026-10-23, "groups that are too tall").
        case tallGroup
        /// The session tree's needs-you tray (`SidebarNeedsYou`): sessions started by other sessions,
        /// some blocked on you (a question, a permission, a sign-in), one failed, two finished unread.
        case needsYou
        /// Groups of one workspace named as the group (what `acpmux new --group X` makes), top level and nested,
        /// beside a group of one differently named member and a group of two (Leo 2026-10-29: "why is there all
        /// this weird stuff at the bottom of the sidebar").
        case soleMember
    }

    /// The state this fixture captures.
    public let scenario: Scenario
    /// The sidebar rows: one local machine section holding the scenario's group tree.
    public let sections: [SidebarSection]

    /// Who started whom (the session tree's `parents`), for ``Scenario/needsYou``; empty for the others.
    public var parents: [WorkspaceID: WorkspaceID] {
        guard scenario == .needsYou else { return [:] }
        let links = ["settings": "release", "shrink": "settings", "notes": "release", "changelog": "notes"]
        return Dictionary(uniqueKeysWithValues: links.map { (WorkspaceID("w-\($0.key)"), WorkspaceID("w-\($0.value)")) })
    }

    /// The sidebar width the scenario is captured at.
    public var width: Double { scenario == .narrow ? 196 : 288 }
    /// The old rails (one per group, stopping at its own last member), for ``Scenario/before``.
    public var legacyRails: Bool { scenario == .before }

    /// Where the scenario's drag is held: over a group's header, or at a row's bottom edge at a level.
    public enum Drop: Hashable, Sendable {
        /// A drop into the group: its header shows the drop fill.
        case into(GroupID)
        /// A drop right after the workspace row, landing at `level`: the gap opens at that level's x.
        case after(WorkspaceID, level: Int)
    }

    /// The drop of a drag scenario; nil for the others.
    public var drop: Drop? {
        switch scenario {
        case .dragInto: .into(GroupID("g-builders"))
        case .dragOut: .after(WorkspaceID("w-derived"), level: 2)
        default: nil
        }
    }

    /// The workspace a drag scenario lifts.
    public var dragged: WorkspaceID? {
        switch scenario {
        case .dragInto, .dragOut: WorkspaceID("w-ios-testflight")
        default: nil
        }
    }

    /// Builds the rows of `scenario`.
    /// - Parameter scenario: the state to capture.
    public init(scenario: Scenario) {
        self.scenario = scenario
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        var nodes: [SidebarNode]
        switch scenario {
        case .before, .after:
            nodes = Self.userTree
        case .depth2:
            nodes = Self.twoLevels
        case .deep, .narrow, .dragInto, .dragOut:
            nodes = Self.sixLevels(folded: [])
        case .collapsed:
            nodes = Self.sixLevels(folded: ["g-builders", "g-sidebar"])
        case .tallGroup:
            nodes = Self.tallGroup
        case .needsYou:
            nodes = Self.needsYouRows.map(SidebarNode.workspace)
        case .soleMember:
            nodes = Self.soleMembers
        }
        sections = [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    private static func ws(_ id: String, _ title: String, unread: UnreadState = .none, busy: Bool = false,
                           activity: StatusIndicatorState? = nil) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: title, unread: unread, activity: activity ?? (busy ? .busy(progress: nil) : .idle))
    }

    /// ``Scenario/needsYou``'s rows, in model order (``parents`` nests them).
    private static let needsYouRows: [SidebarWorkspace] = [
        ws("release", "Release week"), ws("settings", "Settings pass"),
        ws("shrink", "Shrink large files", activity: .waiting(kind: .question)),
        ws("notes", "Release notes", activity: .working), ws("changelog", "Changelog", activity: .waiting(kind: .permission)),
        ws("flaky", "Flaky test hunt", activity: .error), ws("login", "Cloud sign-in", activity: .waiting(kind: .auth)),
        ws("docs", "Docs sweep", unread: .dot), ws("icons", "Icon pass", unread: .count(2)), ws("api", "API cleanup", busy: true),
    ]

    private static func group(_ id: String, _ name: String, _ color: GroupColor, parent: String? = nil, folded: Bool = false,
                              _ members: [SidebarWorkspace]) -> SidebarNode {
        var group = SidebarGroup(id: GroupID("g-\(id)"), name: name, color: color, isCollapsed: folded, workspaces: members)
        group.parent = parent.map { GroupID("g-\($0)") }
        return .group(group)
    }

    /// The groups of the user's 2026-10-21 screenshot, Perf stored under Panes & layout.
    private static let userTree: [SidebarNode] = [
        group("panes", "Panes & layout", .cyan, [
            ws("split-spring", "Split spring"), ws("cmd-d", "Cmd-D in Home"),
            ws("column-resize", "Column resize"), ws("zoom-jank", "Zoom jank"),
        ]),
        group("perf", "Perf", .yellow, parent: "panes", [
            ws("tab-switch", "Tab switch"), ws("pane-lifecycle", "Pane lifecycle"),
            ws("host-slim", "Terminal host slim"), ws("idle-cpu", "Idle CPU", busy: true),
            ws("pane-drag", "Pane drag"), ws("daemon-latency", "Daemon latency", unread: .dot),
            ws("rex-perf", "Rex perf"), ws("ws-switch", "Workspace switch regression"),
        ]),
        group("nightly", "Nightly & CI", .red, [
            ws("updates", "Updates keep sessions alive"), ws("builder", "Nightly builder Mac"),
            ws("ios-testflight", "iOS TestFlight"),
        ]),
    ]

    private static let twoLevels: [SidebarNode] = [
        group("home", "Home & chat", .green, [ws("replies", "Replies animation"), ws("compose", "Home compose")]),
        group("chat-views", "Chat views", .blue, parent: "home", [
            ws("quoted", "Quoted replies", unread: .dot), ws("tables", "Markdown tables"),
        ]),
        group("chat-perf", "Chat switch speed", .purple, parent: "home", [ws("instant", "Instant chat switch", busy: true)]),
        group("panes", "Panes & layout", .cyan, [ws("split-spring", "Split spring"), ws("cmd-d", "Cmd-D in Home")]),
        group("perf", "Perf", .yellow, parent: "panes", [ws("tab-switch", "Tab switch"), ws("idle-cpu", "Idle CPU")]),
        group("nightly", "Nightly & CI", .red, [ws("updates", "Updates keep sessions alive"), ws("ios-testflight", "iOS TestFlight")]),
    ]

    private static let tallGroup: [SidebarNode] = [
        .workspace(ws("readme", "README pass")),
        .workspace(ws("release", "Release notes")),
        group("perf", "Perf", .yellow, [
            ws("tab-switch", "Tab switch"), ws("pane-lifecycle", "Pane lifecycle"), ws("host-slim", "Terminal host slim"),
            ws("idle-cpu", "Idle CPU", busy: true), ws("pane-drag", "Pane drag"), ws("daemon-latency", "Daemon latency", unread: .dot),
            ws("rex-perf", "Rex perf"), ws("ws-switch", "Workspace switch"), ws("scroll", "Scroll jank"), ws("launch", "Cold launch"),
        ]),
        group("home", "Home & chat", .green, [ws("replies", "Replies animation")]),
        group("nightly", "Nightly & CI", .red, [ws("updates", "Updates keep sessions alive"), ws("ios-testflight", "iOS TestFlight")]),
        .workspace(ws("scratch", "Scratch")),
        .workspace(ws("notes", "Notes")),
    ]

    private static let soleMembers: [SidebarNode] = [
        .workspace(ws("readme", "README pass")),
        group("coord", "release-coord", .purple, [ws("coord", "release-coord", busy: true)]),
        group("design", "Design review", .blue, [ws("sketches", "Sketches")]),
        group("visual", "visual-check", .orange, parent: "design", [ws("visual", "visual-check", busy: true)]),
        group("notes", "Release notes", .green, [ws("changelog", "Changelog draft", unread: .dot)]),
        group("nightly", "Nightly & CI", .red, [ws("updates", "nightly-ci"), ws("nightly", "Nightly & CI")]),
    ]

    private static func sixLevels(folded: Set<String>) -> [SidebarNode] {
        [
            group("sidebar", "Sidebar & tabs", .blue, folded: folded.contains("g-sidebar"), [ws("unread-dot", "Pinned unread dot")]),
            group("sidebar-groups", "Groups", .purple, parent: "sidebar", [ws("nested", "Nested groups", unread: .count(3))]),
            group("cloud", "Cloud & fleet", .green, [ws("fleet-status", "Fleet status")]),
            group("minis", "Mac minis", .cyan, parent: "cloud", [ws("mini-health", "Mini health")]),
            group("builders", "Builders", .yellow, parent: "minis", folded: folded.contains("g-builders"),
                  [ws("queue", "Build queue", busy: true)]),
            group("studio", "studio-mac", .orange, parent: "builders", [ws("controller", "Controller")]),
            group("xcode", "Xcode 26", .pink, parent: "studio", [ws("toolchain", "Toolchain pin")]),
            group("caches", "Caches", .red, parent: "xcode", [
                ws("derived", "DerivedData sweep", unread: .dot), ws("spm", "SwiftPM cache", busy: true),
            ]),
            group("nightly", "Nightly & CI", .red, [
                ws("updates", "Updates keep sessions alive"), ws("ios-testflight", "iOS TestFlight"),
            ]),
        ]
    }
}
#endif
