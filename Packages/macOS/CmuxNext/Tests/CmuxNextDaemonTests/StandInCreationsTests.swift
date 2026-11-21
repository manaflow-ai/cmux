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
        store.apply(snapshot: tree(revision: 1))
        return store
    }

    /// The workspace with tab 4 in `pane`, then `more`.
    private static func tree(revision: UInt64, _ more: [TabSnapshot] = []) -> DaemonTree {
        let workspace = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: key, name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                     panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))] + more)])])
        return DaemonTree(workspaceRevision: revision, workspaces: [workspace])
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

    /// A dock's fresh tab, which no reply names, is its stand-in's by the terminal host id the dock minted, after the dock's
    /// intent left the log too: the records and the settlement can land in one apply, before a strip shows the tab (review F1
    /// on #38108; the handover then animated the stand-in closing beside its own tab growing in).
    @Test func aSettledDocksFreshTabIsStillItsStandIns() throws {
        let store = Self.store()
        let (intent, tab) = Self.creation(.dock)
        let standIn = try #require(tab)
        let id = try #require(standIn.tabResourceID?.rawValue), terminal = try #require(standIn.terminalID)
        let transaction = ClientTransactionID.generate()
        store.intend(intent, transaction: transaction)
        store.noteSettledAtNextSnapshot(transaction)
        let fresh = SurfaceID(rawValue: 8)
        store.apply(snapshot: Self.tree(revision: 2, [TabSnapshot(surface: fresh, terminalID: terminal)]))
        try #require(store.pendingIntents.isEmpty, "the dock did not settle; nothing was proven")
        let pane = try #require(store.pane(Self.pane)), made = try #require(store.tab(surface: fresh)).id
        #expect(store.creations.became(standIn: id, tab: made, in: pane), "a settled dock's fresh tab is not known as its stand-in's")
        #expect(!store.creations.became(standIn: ProvisionalTab().id, tab: made, in: pane), "a dock's fresh tab counts as another stand-in's")
    }

    /// A created tab is its own stand-in's only: moved next to another stand-in that leaves, it never takes that one's cell
    /// (review F2 on #38108).
    @Test func aCreatedTabIsOnlyItsOwnStandIns() throws {
        let store = Self.store()
        let first = Self.page(), second = Self.page(), transaction = ClientTransactionID.generate()
        store.intend(.createTab(pane: Self.pane, provisional: first), transaction: transaction)
        let made = SurfaceID(rawValue: 7)
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .tabAdded(TabDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: Self.pane, surface: made, index: 1,
            entity: TabSnapshot(surface: made))))])
        ProvisionalTab.created(transaction, surface: made, in: store)
        store.intend(.createTab(pane: Self.pane, provisional: second), transaction: .generate())
        let pane = try #require(store.pane(Self.pane)), tab = try #require(store.tab(surface: made)).id
        #expect(store.creations.became(standIn: try #require(first.tabResourceID?.rawValue), tab: tab, in: pane), "the tab is not its stand-in's")
        #expect(!store.creations.became(standIn: try #require(second.tabResourceID?.rawValue), tab: tab, in: pane), "the tab counts as another stand-in's")
    }

    /// A stand-in leaving as one tab arrives hands it its cell unless the person closed the stand-in or the tab is another
    /// stand-in's: a swap the strip sees before the tab's record lands keeps its cell (NewTabCloseInterleaveOrderTests'
    /// `.left`, `.daemonTab` reordered to `N b c` for a frame when only a named tab could take it).
    @Test func aLeavingStandInHandsOverUnlessClosedOrAnothers() throws {
        let store = Self.store()
        let open = Self.page(), closed = Self.page(), other = Self.page()
        store.intend(.createTab(pane: Self.pane, provisional: open), transaction: .generate())
        let cancelled = ClientTransactionID.generate(), made = ClientTransactionID.generate()
        store.intend(.createTab(pane: Self.pane, provisional: closed), transaction: cancelled)
        store.intend(.createTab(pane: Self.pane, provisional: other), transaction: made)
        let closedID = try #require(closed.tabResourceID?.rawValue)
        #expect(store.creations.cancel(tab: closedID))
        let theirs = SurfaceID(rawValue: 7), unnamed = SurfaceID(rawValue: 8)
        for (sequence, surface) in [(UInt64(1), theirs), (2, unnamed)] {
            _ = store.apply(batch: [DaemonEventEnvelope(sequence: sequence, event: .tabAdded(TabDelta(
                workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: Self.pane, surface: surface, index: nil,
                entity: TabSnapshot(surface: surface))))])
        }
        ProvisionalTab.created(made, surface: theirs, in: store)
        let pane = try #require(store.pane(Self.pane))
        let openID = try #require(open.tabResourceID?.rawValue)
        let theirTab = try #require(store.tab(surface: theirs)).id, unnamedTab = try #require(store.tab(surface: unnamed)).id
        #expect(store.creations.handsOver(standIn: openID, to: unnamedTab, in: pane), "a tab not yet named lost the open stand-in's cell")
        #expect(!store.creations.handsOver(standIn: closedID, to: unnamedTab, in: pane), "a closed stand-in handed its cell over")
        #expect(!store.creations.handsOver(standIn: openID, to: theirTab, in: pane), "another stand-in's tab took this one's cell")
    }
}
