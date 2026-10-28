#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentLanes
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextOracle
import Foundation
import Testing

/// The oracle's `history` and `notifications` facets. History lists what Recently Closed can reopen,
/// newest first, from the daemons' mirrored closed items, with titles hashed after the runner's case root and home
/// become `$ROOT` and `$HOME`; notifications gives the Dock badge, each workspace's unread count from the store and
/// its Needs you from the agent lanes the sidebar reads. Both read model values in the snapshot's main-actor turn: no
/// disk, no database. Run: `swift test --filter OracleHistoryNotificationsFacetTests`.
@MainActor @Suite(.serialized) struct OracleHistoryNotificationsFacetTests {
    // MARK: History

    private static func browser(_ id: String, _ url: String, at ms: UInt64, empty: Bool = false) -> ClosedItem {
        let tab = ClosedItem.Tab(kind: "browser", url: url, empty: empty)
        return ClosedItem(id: id, kind: .tab, workspaceID: ResourceID("ws_web"), closedAtMs: ms, screens: [.init(tabs: [tab])])
    }

    /// A daemon handshake that serves the state resources (closed history).
    private static func identity() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"oracle-history-test","generation":"g1","capabilities":["\#(DaemonCapability.stateResources.rawValue)"]}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// The app's own facet list over this Mac's daemon, its mirrored closed history set to `closed` in that order.
    private static func services(closed: [ClosedItem]) throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.apply(.connected(try identity(), generationChanged: false))
        var mirror = SessionStateMirror()
        mirror.closed = closed
        store.session.apply(.snapshot(mirror), in: store)
        return services
    }

    /// Through the host's real read (`DaemonClosedHistory.entries`, then Recently Closed's filter): the daemon's items
    /// arrive out of order and the facet lists them newest first, an untouched New Tab page left out and a page closed
    /// twice listed once, at its newest close.
    @Test func candidatesAreNewestFirstWithoutBlankPagesAndAPageClosedTwiceOnce() throws {
        let shell = ClosedItem.Tab(kind: "terminal", name: "build", cwd: "/tmp/case")
        let terminal = ClosedItem(id: "closed_2", kind: .tab, workspaceID: ResourceID("ws_1"), closedAtMs: 2,
                                  screens: [.init(tabs: [shell])])
        let services = try Self.services(closed: [
            Self.browser("closed_1", "https://example.com/a", at: 1),
            Self.browser("closed_4", "https://example.com/a", at: 4),
            terminal,
            Self.browser("closed_3", "about:blank", at: 3, empty: true),
            Self.browser("closed_5", "https://example.com/b", at: 5),
        ])
        let snapshot = try #require(try services.makeOracleFacets().beginCapture([.history]).completed)
        let expected: [OracleHistoryFacet.Closed] = [
            .init(kind: "browser", title: "https://example.com/b", url: "https://example.com/b", workspace: "ws_web"),
            .init(kind: "browser", title: "https://example.com/a", url: "https://example.com/a", workspace: "ws_web"),
            .init(kind: "terminal", title: "build", workspace: "ws_1"),
        ]
        #expect(snapshot["history"] == ["closed": .array(expected.map { $0.value(paths: .unchanged) })])
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

    /// An unnamed shell's title is its cwd, under the case's state root, which here sits inside the hermetic home:
    /// the facet hashes `$ROOT/...`, as normalize.py would write the title before a hash, and one case hashes the
    /// same in every run whatever its state root.
    @Test func aTitleUnderTheRootHashesAsRootEvenWhenTheRootIsInsideTheHome() throws {
        func snapshot(root: String, home: String) throws -> OracleValue? {
            let shells = [ClosedItem.Tab(kind: "terminal", cwd: "\(root)/src"), ClosedItem.Tab(kind: "terminal", cwd: "\(home)/notes")]
            let items = shells.enumerated().map { index, shell in
                ClosedItem(id: "closed_\(index)", kind: .tab, workspaceID: ResourceID("ws_1"), screens: [.init(tabs: [shell])])
            }
            let facets = OracleFacets([OracleHistoryFacet { items }]).rewriting(try OraclePaths(root: [root], home: [home]))
            return try facets.beginCapture([.history]).completed?["history"]
        }
        let first = try snapshot(root: "/Users/me/.cache/o/ab12cd/0001", home: "/Users/me")
        let entry = { (title: String) -> OracleValue in
            ["kind": "terminal", "title": .string(OracleValue.sha256(title)), "url": nil, "workspace": "ws_1"]
        }
        #expect(first == ["closed": [entry("$ROOT/src"), entry("$HOME/notes")]])
        #expect(try snapshot(root: "/tmp/o/zz99yy/0002", home: "/tmp/o/zz99yy/0002-home") == first, "another run's root and home")
    }

    // MARK: Notifications

    private static let host = "install:oracle-notifications"

    private static func tab(_ surface: UInt64, unread: Bool, level: NotificationLevel?, session: String? = nil) -> TabSnapshot {
        let marker = TabNotification(notification: NotificationID(rawValue: surface), unread: unread, level: level, source: "agent")
        guard let session else {
            return TabSnapshot(surface: SurfaceID(rawValue: surface), terminalResourceID: ResourceID(rawValue: "term_\(surface)"),
                               notification: marker)
        }
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, cwd: nil)
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: "claude"))
        tab.notification = marker
        return tab
    }

    private static func workspace(_ id: UInt64, marked: Bool = false, resource: Bool = true, tabs: [TabSnapshot]) -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, resourceID: resource ? ResourceID(rawValue: "ws_\(id)") : nil,
                                 name: "w\(id)", screens: [screen], markedUnread: marked)
    }

    /// The lanes acpmux reports for this Mac's chats: `states` by session.
    private static func lanes(_ states: [String: String]) throws -> (AgentLaneStore, AgentTurnStateStore) {
        let lanes = AgentLaneStore(), turns = AgentTurnStateStore()
        turns.localHost = host
        for (session, state) in states {
            lanes.lanes[session] = try #require(AgentActivityLane.of(summary: ["sessionId": session, "name": session, "lane": ["state": state]]))
        }
        return (lanes, turns)
    }

    private static func reading(_ store: DaemonStore, lanes: AgentLaneStore, turns: AgentTurnStateStore,
                                homeUnread: [String] = []) throws(OracleFacetError) -> OracleNotificationsFacet.Reading? {
        try OracleNotificationsFacet.Reading(store: store, homeUnread: homeUnread) { lanes.needsYou(in: $0, turns: turns) }
    }

    /// Needs you is the chats that wait on the person, as the sidebar and Priority view show it: an ask the person
    /// has seen but not answered still counts, an unread error of a failed turn is unread but not needs-you.
    @Test func needsYouIsTheChatsWaitingOnThePersonReadOrNot() throws {
        _ = NSApplication.shared
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            // A chat that asks, its notification already seen; an unread finished shell turn beside it.
            Self.workspace(1, tabs: [Self.tab(11, unread: false, level: .warning, session: "s-asks"),
                                     Self.tab(12, unread: true, level: .info)]),
            // A failed chat with its unread error.
            Self.workspace(2, tabs: [Self.tab(21, unread: true, level: .error, session: "s-failed")]),
            // Marked unread by hand, nothing unread in it.
            Self.workspace(3, marked: true, tabs: [Self.tab(31, unread: false, level: .info)]),
            // Nothing to count: left out.
            Self.workspace(4, tabs: [Self.tab(41, unread: false, level: nil)]),
        ]))
        let (lanes, turns) = try Self.lanes(["s-asks": "input", "s-failed": "failed"])

        let reading = try #require(try Self.reading(store, lanes: lanes, turns: turns))
        #expect(reading.unread == store.unreadBadge(), "the facet's unread is the Dock badge")
        #expect(reading.workspaces == [.init(id: "ws_1", unread: 1, needsYou: 1), .init(id: "ws_2", unread: 1, needsYou: 0),
                                       .init(id: "ws_3", unread: 1, needsYou: 0)])
        #expect(reading.value == [
            "unread": 3, "needsYou": 1,
            "workspaces": [["workspace": "ws_1", "unread": 1, "needsYou": 1], ["workspace": "ws_2", "unread": 1, "needsYou": 0],
                           ["workspace": "ws_3", "unread": 1, "needsYou": 0]],
        ])

        let withHome = try #require(try Self.reading(store, lanes: lanes, turns: turns, homeUnread: ["conv_a", "conv_a"]))
        #expect(withHome.unread == 4, "an unread Home conversation adds one to the badge, once")
    }

    /// A workspace whose tree is not mirrored has the daemon's unread rollup but nothing that says which chats wait:
    /// the facet is not comparable rather than a needs-you of 0 that would turn into N when the person opens it.
    @Test func aWorkspaceThatIsNotMirroredMakesTheFacetNotComparable() throws {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            Self.workspace(1, tabs: [Self.tab(11, unread: true, level: .info)]),
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: nil, resourceID: ResourceID(rawValue: "ws_2"), name: "lazy",
                              screens: [], unreadCount: 2),
        ]))
        let (lanes, turns) = try Self.lanes([:])
        #expect(try Self.reading(store, lanes: lanes, turns: turns) == nil)

        let facets = OracleFacets([OracleNotificationsFacet { () throws(OracleFacetError) in try Self.reading(store, lanes: lanes, turns: turns) }])
        let value = try #require(try facets.beginCapture([.notifications]).completed?["notifications"])
        #expect(value["status"] == "not-comparable")
        #expect(value["task"] == .string(OracleFacet.notifications.task))
    }

    /// A counted workspace with no public id fails the snapshot: printing another handle would break the schema's
    /// `ws_` id, and leaving it out would hide its counts.
    @Test func aCountedWorkspaceWithNoPublicIDFails() throws {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [Self.workspace(1, resource: false, tabs: [Self.tab(11, unread: true, level: .info)])]))
        let (lanes, turns) = try Self.lanes([:])
        #expect(throws: OracleFacetError.self) { _ = try Self.reading(store, lanes: lanes, turns: turns) }
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
            let title = OracleValue.string(OracleValue.sha256(name))
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
