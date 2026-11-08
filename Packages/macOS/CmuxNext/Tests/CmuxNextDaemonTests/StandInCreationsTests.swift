import Foundation
import Testing
@testable import CmuxNextDaemon

/// Every creation that shows a stand-in tab (a new tab, a new workspace's first tab, a conversation split's tab, a dock's fresh
/// tab) is one to a new tab placed right after that stand-in (`NewTabSuccession`): it is under way until answered or closed,
/// and the daemon's tab that takes its place is known by the stand-in's id. Only a new tab's counted (review F2 on #37799),
/// so a Cmd-T after any other stand-in lost its anchor while the stand-in was out of the records.
@MainActor
struct StandInCreationsTests {
    private static let pane = PaneID(rawValue: 3)
    private static let key = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000005")

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        let tree = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: key, name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                     panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [tree]))
        return store
    }

    private static func page() -> TabSnapshot {
        ProvisionalTab().conversation(ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", hostName: nil)))
    }

    nonisolated enum Kind: String, Sendable, CaseIterable { case newTab, newWorkspace, conversationSplit, dock }

    /// The intent of `kind` and the stand-in tab it shows.
    private static func creation(_ kind: Kind) -> (Intent, TabSnapshot?) {
        switch kind {
        case .newTab:
            let tab = page()
            return (.createTab(pane: pane, provisional: tab), tab)
        case .newWorkspace:
            let tab = page()
            return (.createWorkspace(provisional: ProvisionalWorkspace(key: .generate(), name: "2", tab: tab), index: nil), tab)
        case .conversationSplit:
            let provisional = ProvisionalPane(holding: page())
            return (.splitPane(pane: pane, direction: .right, ratio: 0.5, provisional: provisional), provisional.tab)
        case .dock:
            let tab = ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)
            return (.dockTab(surface: SurfaceID(rawValue: 4), pane: pane, provisional: ProvisionalPane(columnWidth: 0.5, left: true),
                             dock: DockSnapshot(edge: .left, mode: .docked, role: .agentChat), standIn: tab), tab)
        }
    }

    @Test(arguments: Kind.allCases)
    func aStandInIsUnderwayUntilItsCreationLeaves(kind: Kind) throws {
        let store = Self.store()
        let (intent, tab) = Self.creation(kind)
        let id = try #require(tab?.tabResourceID?.rawValue)
        let transaction = ClientTransactionID.generate()
        store.intend(intent, transaction: transaction)
        #expect(store.creations.isUnderway(standIn: id), "a \(kind.rawValue)'s stand-in did not count as under way")
        store.rejectIntent(transaction)
        #expect(!store.creations.isUnderway(standIn: id), "a refused \(kind.rawValue)'s stand-in still counts as under way")
    }

    /// A conversation split's daemon pane names the split's tab (`echoedSplit`): that tab is the stand-in's, as for a new tab.
    @Test func aConversationSplitsTabTakesItsStandInsPlace() throws {
        let store = Self.store()
        let (intent, tab) = Self.creation(.conversationSplit)
        guard case .splitPane(_, _, _, let provisional) = intent else { return }
        let id = try #require(tab?.tabResourceID?.rawValue)
        let transaction = ClientTransactionID.generate()
        store.intend(intent, transaction: transaction)
        let daemon = PaneID(rawValue: 9), made = SurfaceID(rawValue: 7)
        let entity = PaneSnapshot(id: daemon, resourceID: ResourceID(rawValue: provisional.paneID), tabs: [TabSnapshot(surface: made, kind: .conversation)])
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneAdded(PaneDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: daemon, index: 1,
            entity: entity, clientTransactionID: transaction)))])
        #expect(!store.creations.isUnderway(standIn: id), "an answered split's stand-in still counts as under way")
        #expect(store.intentLog.replacement(ofStandIn: id) == made, "the split's daemon tab is not known as its stand-in's")
    }
}
