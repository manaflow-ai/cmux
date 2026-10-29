#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxHomeCore
import CmuxNextAgentActivity
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextHome
import CmuxNextOracle
import CmuxNextPages
import Foundation
import Observation
import os
import Testing

/// The app's agents facet: an agent chat tab's row takes its session and harness from the store
/// record and its state, turn count and open permission requests from acpmux's lane (`turnCount`,
/// `pendingPermissions` of the session summary); a new chat's kept composer text goes in only as its sha256. Each
/// Home Messages view reports the conversation the person sees (none on New Message), and every value is heard
/// by a reader under Observation, as `debug.oracle.wait_for` reads it. Run: `swift test --filter AppOracleAgentsFacetTests`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct AppOracleAgentsFacetTests {
    /// One acpmux session summary with its lane and counts, as the watch sends it.
    private func summary(_ state: String, turnCount: Any? = nil, pendingPermissions: Any? = nil) -> [String: Any] {
        var summary: [String: Any] = ["sessionId": "s-1", "name": "s-1", "harness": "codex",
                                      "lane": ["state": state, "since": 1_760_000_000_000]]
        if let turnCount { summary["turnCount"] = turnCount }
        if let pendingPermissions { summary["pendingPermissions"] = pendingPermissions }
        return summary
    }

    /// Whether `change` notifies a reader of `read`, as a `wait_for` that read it would wake.
    private func heard(_ read: () -> Void, when change: () -> Void) -> Bool {
        let flag = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking(read, onChange: { flag.withLock { $0 = true } })
        change()
        return flag.withLock { $0 }
    }

    @Test func aLaneReadsTheSummarysTurnCountAndOpenPermissions() throws {
        let asking = try #require(AgentActivityLane.of(summary: summary("input", turnCount: 4, pendingPermissions: 2)))
        #expect(asking.turnCount == 4)
        #expect(asking.pendingPermissions == 2)
        let bare = try #require(AgentActivityLane.of(summary: summary("idle")))
        #expect(bare.turnCount == 0 && bare.pendingPermissions == 0, "an acpmux without the counts reads 0")
        let odd = try #require(AgentActivityLane.of(summary: summary("idle", turnCount: -1, pendingPermissions: "2")))
        #expect(odd.turnCount == 0 && odd.pendingPermissions == 0, "a negative or non-number count reads 0")
    }

    @Test func aSessionRowTakesTheLaneAndHashesTheDraft() throws {
        let lane = try #require(AgentActivityLane.of(summary: summary("input", turnCount: 4, pendingPermissions: 2)))
        let row = AppServices.oracleSession(tab: "tab-1", workspace: "ws-1", record: AgentSessionRef(host: "install:a", session: "s-1"),
                                            lane: lane, draft: "hello")
        #expect(row.session == "s-1")
        #expect(row.agent == "codex", "with no harness on the record, the lane's")
        #expect(row.state == .input)
        #expect(row.turn == 4)
        #expect(row.pendingApprovals == 2)
        #expect(row.draftSha256 == "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(row.draftSha256 == OracleValue.sha256("hello"))
        #expect(!String(describing: row.value).contains("hello"), "the draft text never goes in")
    }

    @Test func aNewChatWithNoLaneIsUnknown() {
        let record = AgentSessionRef(host: "install:a", session: nil, harness: "claude")
        let row = AppServices.oracleSession(tab: "tab-2", workspace: nil, record: record, lane: nil, draft: nil)
        #expect(row.session == nil)
        #expect(row.agent == "claude")
        #expect(row.state == .unknown)
        #expect(row.turn == 0 && row.pendingApprovals == 0)
        #expect(row.draftSha256 == nil)
    }

    /// A reader of one tab's draft hears that tab's text change and not another tab's (cx-8w027.20, I2: a pane
    /// snapshot reads its own tab's draft, and typing in another new chat must not re-run it).
    @Test func aDraftChangeIsHeardByThatTabsReaderOnly() {
        let drafts = AgentUnsentDrafts(file: nil)
        #expect(!heard({ _ = drafts.draft(for: "tab-1") }, when: { drafts.set("a reply for the other tab", for: "tab-2") }),
                "another tab's draft woke this tab's reader")
        #expect(heard({ _ = drafts.draft(for: "tab-1") }, when: { drafts.set("compare the two retry policies", for: "tab-1") }))
        #expect(drafts.draft(for: "tab-1") == "compare the two retry policies")
        #expect(heard({ _ = drafts.hasDraft("tab-1") }, when: { drafts.forget("tab-1") }))
        #expect(drafts.draft(for: "tab-1") == nil)
        #expect(drafts.draft(for: "tab-2") == "a reply for the other tab")
    }

    @Test func anAppWithNoAgentTabsListsNone() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.agents))
        let snapshot = try #require(try facets.beginCapture([.agents]).completed)
        #expect(snapshot["agents"] == ["sessions": [], "home": []])
    }

    // MARK: The app's walk (`AppServices.oracleAgents`)

    /// One workspace whose pane holds an agent chat tab of session `s-1` and a Home tab, in services whose Home
    /// store lists conversations; the agents facet reads lanes from `lanes` (the seam), not the app's mirrors.
    @Test func theWalkListsAgentTabsAndHomeTabsAndHearsTheHomeSelection() async throws {
        let services = try await TopHomePageDiscardTests.services()
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:oracle", session: "s-1", harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat])])
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])]))
        let workspace = try #require(services.daemon.store.workspaces.first)
        let pane = try #require(workspace.screens.first?.panes.first)
        let chatTab = try #require(pane.tabs.first)
        let provider = HomePageTab(services: services)
        services.pages.register(provider)
        let homeKey = services.pages.open(.homeTab, in: pane.id, of: services.daemon.store)
        let lanes = AgentLaneStore()
        let working = try #require(AgentActivityLane.of(summary: summary("working", turnCount: 3, pendingPermissions: 1)))
        lanes.lanes = ["s-1": working]

        let snapshot = try #require(try services.makeOracleFacets(lanes: [lanes]).beginCapture([.agents]).completed)
        let session: OracleValue = [
            "tab": .string(chatTab.id), "workspace": .string(workspace.resourceID?.rawValue ?? workspace.id), "session": "s-1",
            "agent": "claude", "state": "working", "turn": 3, "pendingApprovals": 1, "draftSha256": nil,
        ]
        #expect(snapshot["agents"]?["sessions"] == [session])
        #expect(snapshot["agents"]?["home"] == [["window": nil, "tab": .string(homeKey), "conversation": nil]],
                "a Home tab not shown yet shows no conversation")

        let read = { _ = services.oracleAgents { lanes.lane($0) } }
        // The tab's view is made when it first shows: heard, though no view existed at the last read.
        #expect(heard(read, when: { _ = services.pages.view(for: homeKey) }), "the Home tab's view was made unheard")
        let page = try #require(provider.tabs.first?.view)
        let chosen = ConversationID(TopHomePageDiscardTests.conversations[3])
        #expect(heard(read, when: { page.show(chosen) }), "a switch of the shown conversation was not heard")
        #expect(services.oracleAgents { lanes.lane($0) }.home.first?.conversation == chosen.rawValue)

        // New Message shows no conversation (its row is selected), and leaving it shows the conversation again.
        let window = TopHomePageDiscardTests.window()
        defer { window.orderOut(nil) }
        window.contentView = page
        #expect(heard(read, when: { page.presentNewMessage() }), "New Message opened unheard")
        #expect(services.oracleAgents { lanes.lane($0) }.home.first?.conversation == nil, "New Message reported a conversation")
        #expect(heard(read, when: { page.show(chosen) }), "leaving New Message was not heard")
        #expect(services.oracleAgents { lanes.lane($0) }.home.first?.conversation == chosen.rawValue)

        // The lane comes from the seam: a change of its state is heard and read.
        let waiting = try #require(AgentActivityLane.of(summary: summary("input", turnCount: 3, pendingPermissions: 2)))
        #expect(heard(read, when: { lanes.lanes = ["s-1": waiting] }))
        let row = try #require(services.oracleAgents { lanes.lane($0) }.sessions.first)
        #expect(row.state == .input && row.pendingApprovals == 2)
    }

    /// A docked Home's Messages view is heard when made; a window's classic Home page is heard when made.
    @Test func theDockAndTheTopPageAreHeardWhenTheirViewsAreMade() async throws {
        let services = try await TopHomePageDiscardTests.services()
        let dock = HomeDockTab(services: services)
        defer { dock.tabClosed("dock-1") }
        #expect(heard({ _ = dock.messagesViews }, when: { _ = dock.makeView(for: "dock-1", in: nil) }))
        #expect(dock.messagesViews.map(\.key) == ["dock-1"])

        let make: (TopPageRoute, WindowController?) -> (view: NSView, key: String?)? = { route, _ in
            guard route == .home else { return nil }
            return (view: TopHomePageView(services: services, windowKey: { "oracle-agents" }), key: nil)
        }
        let host = TopPageHost(make: make, closed: { _, _ in }, discardable: { _, view in view as? TopHomePageView },
                               title: { $0.rawValue }, discards: false, hiddenLimit: 8, hosts: { [] }, deadline: NoDeadline())
        #expect(host.homePage == nil)
        #expect(heard({ _ = host.homePage }, when: { _ = host.view(for: .home, in: nil) }))
        #expect(host.homePage != nil)
    }

    /// A dock switch is heard, so a reader of the shown view's selection re-reads it.
    @Test func aDockSwitchIsHeard() async {
        let dock = PlainDock(mode: .channels)
        let flag = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = dock.mode } onChange: { flag.withLock { $0 = true } }
        // Messages may always show, so the switch runs whatever the Channels setting is.
        dock.switchTo(.messages)
        await dock.settled()
        #expect(dock.mode == .messages)
        #expect(flag.withLock { $0 }, "a switch from Channels to Messages was not heard")
    }
}

/// A dock whose two views are plain views.
@MainActor
private final class PlainDock: HomeDockSwitchView {
    override func makeContent(for mode: HomeDockMode) -> NSView? { NSView() }
}

@MainActor
private final class NoDeadline: PageDiscardDeadline {
    func arm(after delay: Duration, _ action: @escaping @MainActor () -> Void) {}
    func disarm() {}
}
#endif
