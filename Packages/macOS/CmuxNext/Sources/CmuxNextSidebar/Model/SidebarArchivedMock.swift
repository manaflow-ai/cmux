#if DEBUG
import CmuxNextDesign

/// SCRATCH mockup (archived-variations gallery, Lawrence 2026-10-30): the `archived` scenario of
/// `debug.sidebar_nested_fixture`, 12 archived workspaces of 23 (three groups and the loose list), drawn with
/// `sidebar.archivedLook`, and the Tidy Up card of `sidebar.archivedTidy`. English only: a mockup, never shipped.
nonisolated struct SidebarArchivedMock {
    private static let prefix = "w-amock-"

    /// Whether `sections` are this fixture's (they keep their own archived marks).
    static func isFixture(_ sections: [SidebarSection]) -> Bool {
        sections.first?.workspaces.first?.id.rawValue.hasPrefix(prefix) == true
    }

    /// The Tidy Up card of `tidy`; nil for the variants with no card.
    static func card(_ tidy: SidebarArchivedTidy) -> SidebarNoticeCard? {
        typealias Action = SidebarNoticeCard.Action
        switch tidy {
        case .card:
            return SidebarNoticeCard(id: "mock.tidy.card", symbol: "archivebox", title: "Archive 3 idle workspaces?",
                                     actions: [Action(id: "archive", title: "Archive", prominent: true),
                                               Action(id: "always", title: "Always Archive")],
                                     dismissLabel: "Not Now")
        case .oneLine:
            return SidebarNoticeCard(id: "mock.tidy.oneline", symbol: "archivebox", title: "3 idle workspaces",
                                     dismissLabel: "Archive 3 idle workspaces", dismissTitle: "Archive")
        case .toggle:
            return SidebarNoticeCard(id: "mock.tidy.toggle", symbol: "archivebox", title: "Archive 3 idle workspaces?",
                                     actions: [Action(id: "archive", title: "Archive", prominent: true)], dismissLabel: "Not Now")
        case .off, .rowHint, .toast:
            return nil
        }
    }

    private static func ws(_ id: String, _ title: String, archived: Bool = false, unread: UnreadState = .none,
                           busy: Bool = false) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(prefix + id), title: title, unread: unread, activity: busy ? .busy(progress: nil) : .idle)
        row.isArchived = archived
        return row
    }

    private static func group(_ id: String, _ name: String, _ color: GroupColor, _ members: [SidebarWorkspace]) -> SidebarNode {
        .group(SidebarGroup(id: GroupID("g-\(id)"), name: name, color: color, isCollapsed: false, workspaces: members))
    }

    /// Archived rows last in each list, as the reducer keeps them.
    static var nodes: [SidebarNode] {
        [
            group("next", "cmux-next", .blue, [
                ws("sidebar", "Sidebar archived look", busy: true), ws("tidy", "Tidy Up card", unread: .dot),
                ws("palette", "Palette scopes"), ws("home", "Home compose"),
                ws("old-drag", "Tab drag spike", archived: true), ws("old-bench", "Bench run 10-12", archived: true),
                ws("old-notes", "Release 0.71 notes", archived: true),
            ]),
            group("infra", "Infra", .green, [
                ws("fleet", "Fleet queue"), ws("mini", "Mini health"),
                ws("old-xcode", "Xcode 26.1 pin", archived: true), ws("old-cache", "Cache sweep", archived: true),
            ]),
            group("docs", "Docs", .purple, [
                ws("guide", "Getting started guide"),
                ws("old-faq", "FAQ rewrite", archived: true), ws("old-jp", "Japanese pass", archived: true),
                ws("old-shots", "Screenshot refresh", archived: true), ws("old-links", "Dead links", archived: true),
            ]),
            .workspace(ws("scratch", "Scratch")), .workspace(ws("review", "PR review", unread: .count(2))),
            .workspace(ws("old-a", "Old repro", archived: true)), .workspace(ws("old-b", "Try zig 0.15", archived: true)),
            .workspace(ws("old-c", "Lunch notes", archived: true)),
        ]
    }
}
#endif
