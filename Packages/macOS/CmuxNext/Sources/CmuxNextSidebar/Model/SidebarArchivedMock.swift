#if DEBUG
import CmuxNextDesign

/// SCRATCH mockup (archive-layout gallery round 2, Lawrence msg 19197, 2026-10-31): the `archiveLayout` scenario of
/// `debug.sidebar_nested_fixture`, shaped like his sidebar: 28 groups (7 archived, 2 with every member archived, 2
/// with some archived), 29 archived loose workspaces, 45 archived in all. `sidebar.archiveLayout` picks where the
/// archived things go. English only: a mockup, never shipped.
nonisolated struct SidebarArchivedMock {
    private static let prefix = "w-amock-"

    /// Whether `sections` are this fixture's (they keep their own archived marks).
    static func isFixture(_ sections: [SidebarSection]) -> Bool {
        sections.contains { $0.workspaces.contains { $0.id.rawValue.hasPrefix(prefix) } }
    }

    private struct Member {
        var id: String
        var title: String
        var archived = false
        var unread: UnreadState = .none
        var busy = false
    }

    private struct Group {
        var id: String
        var name: String
        var color: GroupColor
        var collapsed = false
        /// The group itself is archived.
        var archived = false
        var members: [Member]
        /// Archived, or every member archived: it moves into the archive whole.
        var goesWhole: Bool { archived || (!members.isEmpty && members.allSatisfy(\.archived)) }
    }

    private static func m(_ id: String, _ title: String, unread: UnreadState = .none, busy: Bool = false) -> Member {
        Member(id: id, title: title, unread: unread, busy: busy)
    }

    private static func a(_ id: String, _ title: String) -> Member { Member(id: id, title: title, archived: true) }

    /// The groups in his sidebar's order (msg 19197 screenshot).
    private static let groups: [Group] = [
        Group(id: "chief", name: "Chief", color: .blue, members: [
            m("compose", "Chief home compose"), m("voice", "Chief voice notes", busy: true), m("picker", "Chief model picker", unread: .dot),
        ]),
        Group(id: "cloud", name: "Cloud", color: .cyan, members: [
            m("snap", "Cloud environments snapshots"), m("meter", "Cloud VM metering eval"), m("feedback", "Customer feedback actionables"),
            m("cohesion", "Cloud cohesion map"), a("billing-spike", "Cloud billing spike"), a("old-image", "Old VM image"),
        ]),
        Group(id: "audit", name: "Audit", color: .purple, members: [m("traj", "Chief trajectory audit")]),
        Group(id: "onboarding", name: "Onboarding", color: .purple, members: [m("intro", "First-open Chief intro")]),
        Group(id: "terminals", name: "Terminals", color: .cyan, members: [m("white", "Terminal white after restart")]),
        Group(id: "panes", name: "Panes", color: .yellow, members: [m("resize", "Resize modifier modes"), a("zoom", "Split zoom glitch")]),
        Group(id: "labs", name: "Labs", color: .orange, members: [m("room", "Always-on voice/screen AI room")]),
        Group(id: "paid", name: "Paid plans", color: .red, members: [m("plans", "Paid plans and onboarding")]),
        Group(id: "docs", name: "Docs", color: .pink, members: [m("docs", "cmux-next docs")]),
        Group(id: "personal", name: "Personal apps", color: .green, members: [m("sleepstats", "Sleep alarm analytics")]),
        Group(id: "ci", name: "CI & builds", color: .yellow, members: [
            m("gate", "Review gate vs PL-guardrails"), m("perfile", "Push gate per-file match", busy: true), m("red", "Fix red feat-cmux-next CI"),
            m("fleetapi", "Fleet controller job API down", unread: .count(2)), m("blacksmith", "CI to Blacksmith everywhere"),
        ]),
        Group(id: "sleep", name: "Sleep alarm", color: .purple, members: []),
        Group(id: "iosapps", name: "iOS apps", color: .pink, collapsed: true, members: [m("tf", "TestFlight upload"), m("widget", "Widget sizes")]),
        Group(id: "agents", name: "Agents & routing", color: .grey, collapsed: true, members: [
            m("route", "Subrouter health"), m("acp", "ACP session restore"), m("codex", "Codex harness pin"),
        ]),
        Group(id: "markdown", name: "Markdown & editor", color: .purple, collapsed: true, members: [m("md", "Markdown tables"), m("vim", "Vim mode")]),
        Group(id: "iosmobile", name: "iOS & mobile", color: .pink, collapsed: true, members: [m("pair", "Phone pairing"), m("push", "Push relay")]),
        Group(id: "spaces", name: "Spaces", color: .green, archived: true, members: [a("spaces1", "Spaces picker"), a("spaces2", "Space colors")]),
        Group(id: "updates", name: "Updates", color: .cyan, archived: true, members: [a("sparkle", "Sparkle delta feed")]),
        Group(id: "cloudfleet", name: "Cloud & fleet", color: .cyan, collapsed: true, archived: true, members: [
            a("lease", "Lease timeouts"), a("minis", "Mini disk sweep"), a("queue", "Queue status page"),
        ]),
        Group(id: "web", name: "Web", color: .red, members: [a("landing", "Landing page hero")]),
        Group(id: "nightly", name: "Nightly & CI", color: .orange, collapsed: true, members: [m("nightly", "Nightly notes"), m("dmg", "DMG size")]),
        Group(id: "perf", name: "Perf", color: .orange, collapsed: true, archived: true, members: [
            a("typing", "Typing latency trace"), a("scroll", "Scroll perf pass"),
        ]),
        Group(id: "accounts", name: "Accounts & billing", color: .red, collapsed: true, members: [m("stripe", "Stripe webhooks"), m("seats", "Team seats")]),
        Group(id: "security", name: "Security audit", color: .pink, collapsed: true, members: [m("keys", "Key storage review"), m("csp", "CSP headers")]),
        Group(id: "models", name: "Chief models", color: .orange, members: [a("modelpick", "Model fallback order")]),
        Group(id: "extensions", name: "Extensions", color: .blue, archived: true, members: [a("ext", "Extension sandbox")]),
        Group(id: "vault", name: "Vault", color: .grey, archived: true, members: [a("vault", "Vault unlock flow")]),
        Group(id: "groupsidebar", name: "Group Sidebar", color: .grey, archived: true, members: [a("gside", "Group drag spike")]),
    ]

    /// The 29 archived loose workspaces, latest archived first.
    private static let looseArchived: [Member] = [
        "Tab drag repro", "Try zig 0.15", "Bench run 10-12", "Release 0.71 notes", "Xcode 26.1 pin", "Cache sweep",
        "FAQ rewrite", "Japanese pass", "Screenshot refresh", "Dead links", "Sparkle feed check", "Font fallback test",
        "Ghostty bump", "Socket latency probe", "Notarize retry", "Crash triage 10-24", "Glass tint tweak", "Login loop repro",
        "Theme import", "Keymap audit", "Dock badge bug", "Scrollback perf", "Agent pane spike", "Copy mode fix",
        "Window restore", "DMG layout", "Palette ranking", "Hover card timing", "Status bar polish",
    ].enumerated().map { Member(id: "loose\($0.offset)", title: $0.element, archived: true) }

    private static let looseActive = [m("tmux", "tmux + proxied browser (Mac mini)")]

    /// What the layout draws besides the rows (`SidebarLayoutOptions/archiveMock`).
    static func info(_ layout: SidebarArchiveLayout) -> SidebarArchiveMockInfo {
        let total = groups.flatMap(\.members).filter(\.archived).count + looseArchived.count
        return SidebarArchiveMockInfo(layout: layout, total: total, colors: groups.filter(\.goesWhole).map(\.color))
    }

    private static func ws(_ member: Member, archived: Bool) -> SidebarWorkspace {
        let id = prefix + (member.archived ? "x-" : "") + member.id
        var row = SidebarWorkspace(id: WorkspaceID(id), title: member.title, unread: member.unread,
                                   activity: member.busy ? .busy(progress: nil) : .idle)
        row.isArchived = archived
        return row
    }

    private static func node(_ group: Group, members: [Member], archive: Bool, dims: Bool = true, collapsed: Bool? = nil) -> SidebarNode {
        var g = SidebarGroup(id: GroupID("g-amock-" + (archive ? "x-" : "") + group.id), name: group.name, color: group.color,
                             isCollapsed: collapsed ?? group.collapsed, workspaces: members.map { ws($0, archived: dims && $0.archived) })
        g.isArchived = dims && (group.archived || archive)
        return .group(g)
    }

    /// Loose rows, archived marks as `archived` says.
    private static func loose(_ members: [Member], archived: Bool) -> [SidebarNode] {
        members.map { member -> SidebarNode in SidebarNode.workspace(ws(member, archived: archived && member.archived)) }
    }

    /// The groups and loose rows with nothing archived in them (partly archived groups lose their archived members;
    /// with `keepsArchivedMembers`, E, they keep them for the header's count).
    private static func active(keepsArchivedMembers: Bool = false) -> [SidebarNode] {
        var nodes: [SidebarNode] = []
        for group in groups where !group.goesWhole {
            let members = keepsArchivedMembers ? group.members : group.members.filter { !$0.archived }
            nodes.append(node(group, members: members, archive: false))
        }
        return nodes + loose(looseActive, archived: false)
    }

    /// The archive's own rows: the partly archived groups' archived members under a copy of their header, the archived
    /// groups whole, then the archived loose rows; dimmed unless `dims` is false (D's Archive page).
    private static func archive(dims: Bool) -> [SidebarNode] {
        var nodes: [SidebarNode] = []
        for group in groups where group.members.contains(where: \.archived) || group.archived {
            let members = group.members.filter(\.archived)
            nodes.append(node(group, members: members, archive: true, dims: dims, collapsed: false))
        }
        return nodes + loose(looseArchived, archived: dims)
    }

    /// The fixture's nodes for `layout`.
    static func nodes(_ layout: SidebarArchiveLayout) -> [SidebarNode] {
        switch layout {
        case .today:
            let grouped: [SidebarNode] = groups.map { group -> SidebarNode in node(group, members: group.members, archive: group.archived) }
            return grouped + loose(looseArchived, archived: true) + loose(looseActive, archived: false)
        case .section, .footer, .chips, .hidden, .header, .pageActive:
            return active()
        case .badge:
            return active(keepsArchivedMembers: true)
        case .sectionOpen:
            return active() + archive(dims: true)
        case .pageArchive:
            return archive(dims: false)
        case .peek:
            return active() + loose(Array(looseArchived.prefix(3)), archived: true)
        }
    }
}
#endif
