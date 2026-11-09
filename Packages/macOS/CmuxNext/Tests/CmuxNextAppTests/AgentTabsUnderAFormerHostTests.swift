import CmuxNextActions
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Leo, 2026-11-09, on his own Mac (a tagged DEV build): "This chat belongs to another machine, so it
/// does not run here." #36015 attached a tab this Mac's tree saved under a former install id
/// (`install:<backend id>`, #35284) to this Mac's acpmux, but every other check compared the record's
/// host with this Mac's exactly: the sidebar's session tree put the chat in its remote bucket, the
/// duplicate-tab lookup missed it, and the open refused it. This Mac's own daemon's tree reads such a
/// tab under this Mac's current host (``DaemonStore/formerLocalHosts``); another machine's listing
/// keeps the host it saved, so no exact check takes another machine's tab for this Mac's.
@MainActor struct AgentTabsUnderAFormerHostTests {
    private static let current = AgentSessionRef.host(installID: "mac-before")
    private static let former = AgentSessionRef.host(installID: "mac-staging")

    /// A tree of one workspace whose one tab is a chat on session `s-1` saved under ``former``.
    private static func store(aliasesFirst: Bool, local: Bool = true) -> DaemonStore {
        let store = DaemonStore()
        if aliasesFirst, local { store.formerLocalHosts = [former: current] }
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: former, hostName: "office-mac", session: "s-1"))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)),
                                    panes: [PaneSnapshot(id: PaneID(rawValue: 1), tabs: [chat])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])]))
        // Former ids read after the tree arrived (Cloud start's read ended later) reach the listed tabs too.
        if !aliasesFirst, local { store.formerLocalHosts = [former: current] }
        return store
    }

    private static func tab(_ store: DaemonStore) -> TabModel? { store.tab(surface: SurfaceID(rawValue: 1)) }

    @Test(arguments: [true, false]) func thisMacsTreeReadsAFormerHostAsThisMacsCurrentOne(aliasesFirst: Bool) throws {
        let store = Self.store(aliasesFirst: aliasesFirst)
        let record = try #require(Self.tab(store)?.agentSession)
        #expect(record.host == Self.current)
        #expect(record.hostName == "office-mac" && record.session == "s-1", "only the host is read anew")
    }

    /// Another machine's tree naming that id keeps it: that machine's tab, never this Mac's.
    @Test func anotherMachinesTreeKeepsTheHostItSaved() throws {
        let store = Self.store(aliasesFirst: true, local: false)
        #expect(try #require(Self.tab(store)?.agentSession).host == Self.former)
    }

    /// The sidebar's session tree finds the chat among this Mac's sessions, not in its remote bucket.
    @Test func theSessionTreeCountsTheChatAsThisMacs() {
        let chats = SidebarSessionTreeFeed.chats(Self.store(aliasesFirst: false).workspaces)
        let shown = SidebarSessionTreeFeed.workspaces(showing: ["s-1"], in: chats, localHost: Self.current)
        #expect(shown.values.sorted() == ["s-1"])
        let elsewhere = SidebarSessionTreeFeed.chats(Self.store(aliasesFirst: true, local: false).workspaces)
        #expect(SidebarSessionTreeFeed.workspaces(showing: ["s-1"], in: elsewhere, localHost: Self.current).isEmpty)
    }

    /// Opening the chat again finds its tab (no duplicate), and its host is this Mac's: no refusal.
    @Test func openingTheChatFindsItsTabAndRefusesNothing() throws {
        let store = Self.store(aliasesFirst: false)
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(), environment: [:], showcase: true)
        tabs.localHost = Self.current
        // As AgentTabs+Wiring lists every tree's chats: by each tab's record.
        tabs.listTabsScoped = { store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).compactMap { tab in
            tab.agentSession.map { (key: tab.id, record: $0, machine: "") }
        } }
        let key = try #require(Self.tab(store)?.id)
        #expect(tabs.tab(showing: "s-1") == key)
        let record = try #require(Self.tab(store)?.agentSession)
        #expect(AgentTabStore.hostRefusal(record.host, localHost: tabs.localHost, chiefHost: nil, daemonIsLocal: true) == nil)
    }
}
