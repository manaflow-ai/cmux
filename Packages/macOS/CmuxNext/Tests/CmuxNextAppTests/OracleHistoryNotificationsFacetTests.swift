#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowserTabs
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextOracle
import Foundation
import Testing

/// The oracle's `history` and `notifications` facets (p15-oracle-042). History lists what Recently Closed can reopen,
/// newest first, from the daemons' mirrored closed items, with titles hashed after the home directory becomes
/// `$HOME`; notifications gives the Dock badge and each workspace's unread and needs-you counts from the store.
/// Both read model values in the snapshot's main-actor turn: no disk, no database.
/// Run: `swift test --filter OracleHistoryNotificationsFacetTests`.
@MainActor @Suite(.serialized) struct OracleHistoryNotificationsFacetTests {
    // MARK: History

    private static func browser(_ id: String, _ url: String, at ms: UInt64, empty: Bool = false) -> ClosedItem {
        let tab = ClosedItem.Tab(kind: "browser", url: url, empty: empty)
        return ClosedItem(id: id, kind: .tab, workspaceID: ResourceID("ws_web"), closedAtMs: ms, screens: [.init(tabs: [tab])])
    }

    @Test func candidatesAreNewestFirstWithoutBlankPagesAndAPageClosedTwiceOnce() {
        let shell = ClosedItem.Tab(kind: "terminal", name: "build", cwd: "/tmp/case")
        let terminal = ClosedItem(id: "closed_2", kind: .tab, workspaceID: ResourceID("ws_1"), closedAtMs: 2,
                                  screens: [.init(tabs: [shell])])
        let closed: [(item: ClosedItem, machine: String)] = [
            (Self.browser("closed_4", "https://example.com/a", at: 4), "local"),
            (Self.browser("closed_3", "about:blank", at: 3, empty: true), "local"),
            (terminal, "local"),
            (Self.browser("closed_1", "https://example.com/a", at: 1), "local"),
        ]
        // The host's read: Recently Closed's list of the daemons' closed items.
        let candidates = TabSearchFactsBuilder.listed(closed) { $0 }.map { OracleHistoryFacet.Closed($0.item) }
        #expect(candidates == [
            .init(kind: "browser", title: "https://example.com/a", url: "https://example.com/a", workspace: "ws_web"),
            .init(kind: "terminal", title: "build", workspace: "ws_1"),
        ])
    }

    @Test func eachItemKindNamesWhatAReopenRecreates() {
        let shell = ClosedItem.Tab(kind: "terminal", cwd: "/tmp/case")
        var page = ClosedItem.Tab(kind: "browser", name: "Settings", url: "about:blank")
        page.page = "settings"
        let items = [
            ClosedItem(id: "closed_1", kind: .tab, screens: [.init(tabs: [shell, shell])]),
            ClosedItem(id: "closed_2", kind: .tab, screens: [.init(tabs: [page])]),
            ClosedItem(id: "closed_3", kind: .screen, name: "logs", screens: [.init(tabs: [shell])]),
            ClosedItem(id: "closed_4", kind: .workspace, name: "api", screens: [.init(tabs: [shell])]),
            ClosedItem(id: "closed_5", kind: .workspace, group: .init(id: "grp_1", name: "Team")),
        ]
        let closed = items.map { OracleHistoryFacet.Closed($0) }
        #expect(closed.map(\.kind) == ["tabs", "page", "screen", "workspace", "group"])
        #expect(closed.map(\.title) == ["/tmp/case", "Settings", "logs", "api", "Team"])
        #expect(closed.allSatisfy { $0.url == nil }, "only a closed browser tab has an address")
    }

    @Test func theTitleIsHashedAfterTheHomeDirectoryBecomesHome() throws {
        #expect(OracleHistoryFacet.rewritingHome("/Users/me/src (zsh)", home: "/Users/me/") == "$HOME/src (zsh)")
        #expect(OracleHistoryFacet.rewritingHome("cd /Users/me && ls /Users/me", home: "/Users/me") == "cd $HOME && ls $HOME")
        #expect(OracleHistoryFacet.rewritingHome("/Users/meow/src", home: "/Users/me") == "/Users/meow/src",
                "a longer name that starts with the home path is kept")
        #expect(OracleHistoryFacet.rewritingHome("/Users/me/src", home: nil) == "/Users/me/src")

        let shell = ClosedItem.Tab(kind: "terminal", cwd: "/Users/me/src")
        let items = [ClosedItem(id: "closed_1", kind: .tab, workspaceID: ResourceID("ws_1"), screens: [.init(tabs: [shell])])]
        let facet = OracleHistoryFacet(home: "/Users/me") { items }
        let snapshot = try #require(try OracleFacets([facet]).beginCapture([.history]).completed)
        let entry: OracleValue = [
            "kind": "terminal", "title": .string(OracleHistoryFacet.hash("$HOME/src")), "url": nil, "workspace": "ws_1",
        ]
        #expect(snapshot["history"] == ["closed": [entry]])
        #expect(OracleHistoryFacet.hash("$HOME/src") == OracleTabsFacet.Tab.hash("$HOME/src"), "one derive for every facet")
    }

    // MARK: Notifications

    private static func tab(_ surface: UInt64, unread: Bool, level: NotificationLevel?) -> TabSnapshot {
        let marker = TabNotification(notification: NotificationID(rawValue: surface), unread: unread, level: level, source: "agent")
        return TabSnapshot(surface: SurfaceID(rawValue: surface), terminalResourceID: ResourceID(rawValue: "term_\(surface)"),
                           notification: marker)
    }

    private static func workspace(_ id: UInt64, marked: Bool = false, tabs: [TabSnapshot]) -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, resourceID: ResourceID(rawValue: "ws_\(id)"), name: "w\(id)",
                                 screens: [screen], markedUnread: marked)
    }

    @Test func theCountsAreTheBadgeAndEachWorkspacesUnreadAndAsks() {
        _ = NSApplication.shared
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            // An unread finished turn, an unread ask, a read error.
            Self.workspace(1, tabs: [Self.tab(11, unread: true, level: .info), Self.tab(12, unread: true, level: .warning),
                                     Self.tab(13, unread: false, level: .error)]),
            // Marked unread by hand, nothing unread in it.
            Self.workspace(2, marked: true, tabs: [Self.tab(21, unread: false, level: .info)]),
            // Nothing to count: left out.
            Self.workspace(3, tabs: [Self.tab(31, unread: false, level: nil)]),
        ]))

        let reading = OracleNotificationsFacet.Reading(store: store, homeUnread: [])
        #expect(reading.unread == 3)
        #expect(reading.unread == store.unreadBadge(), "the facet's unread is the Dock badge")
        #expect(reading.workspaces == [.init(id: "ws_1", unread: 2, needsYou: 1), .init(id: "ws_2", unread: 1, needsYou: 0)])
        #expect(reading.needsYou == 1)
        #expect(reading.value == [
            "unread": 3, "needsYou": 1,
            "workspaces": [["workspace": "ws_1", "unread": 2, "needsYou": 1], ["workspace": "ws_2", "unread": 1, "needsYou": 0]],
        ])

        let withHome = OracleNotificationsFacet.Reading(store: store, homeUnread: ["conv_a", "conv_a"])
        #expect(withHome.unread == 4, "an unread Home conversation adds one to the badge, once")
    }

    @Test func theAppListProvidesBothFacets() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.history))
        #expect(facets.provided.contains(.notifications))
        #expect(facets.duplicates.isEmpty)
    }

    // MARK: Close and reopen, through the app against a same-tree daemon

    /// A closed tab is the history facet's newest entry, and reopening it takes it out.
    @Test(.timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aClosedTabIsTheNewestEntryUntilItIsReopened() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let window = try #require(services.windows.active)
            let pane = try #require(window.workspaceContent?.panes.values.first?.pane)
            _ = try await connection.newTab(in: pane.handle)
            try await PinnedPageTests.until({ pane.tabs.count == 2 }, within: .seconds(30), report: { "\(pane.tabs.count) tabs" })
            let name = "closed-\(UUID().uuidString.prefix(6).lowercased())"
            let closing = try #require(pane.tabs.last)
            try await connection.renameTab(closing.surface, to: name)
            try await PinnedPageTests.until({ closing.name == name }, report: { "\(String(describing: closing.name))" })
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let title = OracleValue.string(OracleHistoryFacet.hash(OracleHistoryFacet.rewritingHome(name, home: home)))
            let newest = { () -> OracleValue? in
                guard case .array(let closed)? = try? services.makeOracleFacets().beginCapture([.history]).completed?["history"]?["closed"]
                else { return nil }
                return closed.first
            }

            let closed = try await Self.perform("closeTab", ActionInvocation(target: ActionTargetRef(kind: .tab, id: closing.id)), services)
            #expect(closed.isEmpty, "\(closed)")
            try await PinnedPageTests.until({ newest()?["title"] == title }, report: { "newest: \(String(describing: newest()))" })
            #expect(newest()?["kind"] == "terminal")
            #expect(newest()?["workspace"] == window.workspaceContent?.workspace.resourceID.map { OracleValue.string($0.rawValue) })

            let reopened = try await Self.perform("reopenClosedBrowserPanel", ActionInvocation(origin: .cli), services)
            #expect(reopened.isEmpty, "\(reopened)")
            try await PinnedPageTests.until({ pane.tabs.contains { $0.name == name } }, report: { "\(pane.tabs.map(\.name))" })
            try await PinnedPageTests.until({ newest()?["title"] != title }, report: { "still newest: \(String(describing: newest()))" })
        }
    }

    private static func perform(_ id: ActionID, _ invocation: ActionInvocation, _ services: AppServices) async throws -> [String] {
        var ran = false
        var work: [ActionWork] = []
        let refusal = services.registry.capturingRefusal {
            work = services.registry.capturingWork { ran = services.registry.perform(id, invocation: invocation) }
        }
        var failures = refusal.map { [$0] } ?? []
        if !ran { failures.append("\(id) did not run") }
        for task in work { if let failure = await task.value { failures.append(failure.message) } }
        return failures
    }
}
#endif
