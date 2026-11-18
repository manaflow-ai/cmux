import Foundation
import Testing
@testable import CmuxNextDaemon

/// The instant-create guard (Cmd-N, Cmd-T, Cmd-D, Cmd-Shift-D; instant-new-surfaces): each
/// command's result is in the store's visible records in the same turn as its intent, with no
/// daemon connected at all, so nothing on the key path can wait for a reply. The daemon's answer
/// then takes the stand-in over in place, and a refusal removes it exactly.
@MainActor
struct InstantCreateIntentTests {
    private static let pane = PaneID(rawValue: 3)

    /// One workspace with one screen and one pane holding one terminal tab.
    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [base]))
        return store
    }

    private static let baseKey = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001")
    private static let base = WorkspaceSnapshot(
        id: WorkspaceHandle(rawValue: 1), key: baseKey, name: "1",
        screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                 panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])])])

    private static func page() -> TabSnapshot {
        ProvisionalTab().conversation(ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", hostName: nil)))
    }

    // MARK: Cmd-N

    @Test func newWorkspaceShowsWithItsPageInTheIntentsTurn() throws {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let tab = Self.page()
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: "2", tab: tab), index: nil),
                     transaction: .generate())

        let shown = try #require(store.workspace(id: key.rawValue))
        #expect(shown.isProvisional)
        #expect(shown.name == "2")
        #expect(shown.screens.flatMap(\.panes).flatMap(\.tabs).map(\.surface) == [tab.surface])
        #expect(store.workspaces.count == 2)
    }

    @Test func daemonWorkspaceTakesTheModelOverAndKeepsThePageUntilItsTab() throws {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let tab = Self.page()
        let transaction = ClientTransactionID.generate()
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: "2", tab: tab), index: nil),
                     transaction: transaction)
        let shown = try #require(store.workspace(id: key.rawValue))

        // create-workspace answered: the daemon's workspace, no screen yet.
        let created = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 9), key: key, name: "2")
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [Self.base, created]))
        #expect(store.workspace(id: key.rawValue) === shown)
        #expect(!shown.isProvisional)
        #expect(shown.screens.flatMap(\.panes).flatMap(\.tabs).map(\.surface) == [tab.surface], "no frame shows it empty")

        // Its first tab landed: the daemon's records alone show it, under the same model.
        let pane = PaneID(rawValue: 10)
        var withTab = created
        withTab.screens = [ScreenSnapshot(id: ScreenID(rawValue: 11), active: true, activePane: pane, layout: .leaf(pane),
                                          panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 12), kind: .conversation)])])]
        store.noteSettledAtNextSnapshot(transaction)
        store.apply(snapshot: DaemonTree(workspaceRevision: 3, workspaces: [Self.base, withTab]))
        #expect(store.pendingIntents.isEmpty)
        #expect(store.workspace(id: key.rawValue) === shown)
        #expect(shown.screens.flatMap(\.panes).flatMap(\.tabs).map(\.surface) == [SurfaceID(rawValue: 12)])
    }

    /// A chat opened in a new workspace (agent.openSessionWorkspace, Open Chat) shows its workspace and chat tab as
    /// stand-ins. The daemon sends its first tab twice: a raw `tab-added` with no transaction as it makes the tab, then
    /// the copy carrying the create's transaction. The raw one named no create, so the stand-in's screen gave way to the
    /// daemon's tab under the daemon's id before the echo moved the chat's page to it: the window built a second page for
    /// that id and dropped the stand-in's (a chat-open bench open on cmux21 had no first content, job 65f51c2d). As for a
    /// created tab (tab-spam-race), the raw tab is the oldest waiting create's guess: hidden, the stand-in showing, until
    /// the echo or the reply names it.
    @Test func aNewWorkspacesRawFirstTabKeepsTheStandInUntilItsCreateIsNamed() throws {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let record = AgentSessionRef(host: "install:test", hostName: nil, session: "s-chat")
        let tab = ProvisionalTab().conversation(ConversationTabRef(agentSession: record))
        let transaction = ClientTransactionID.generate()
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: "chat", tab: tab), index: nil),
                     transaction: transaction)
        let shown = try #require(store.workspace(id: key.rawValue))

        // create-workspace answered: the daemon's workspace, with its screen and an empty pane.
        let pane = PaneID(rawValue: 10), screen = ScreenID(rawValue: 11), workspace = WorkspaceHandle(rawValue: 9)
        let created = WorkspaceSnapshot(id: workspace, key: key, name: "chat",
                                        screens: [ScreenSnapshot(id: screen, active: true, activePane: pane, layout: .leaf(pane),
                                                                 panes: [PaneSnapshot(id: pane, tabs: [])])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [Self.base, created]))
        func surfaces() -> [SurfaceID] { shown.screens.flatMap(\.panes).flatMap(\.tabs).map(\.surface) }
        #expect(surfaces() == [tab.surface], "the stand-in shows until the daemon's tab")

        // The daemon's raw tab-added (no transaction): nothing names its create yet.
        let daemonSurface = SurfaceID(rawValue: 12)
        var entity = TabSnapshot(surface: daemonSurface, kind: .conversation)
        entity.conversation = ConversationTabRef(agentSession: record)
        func added(_ transaction: ClientTransactionID?, sequence: UInt64) -> DaemonEventEnvelope {
            DaemonEventEnvelope(sequence: sequence, event: .tabAdded(TabDelta(workspace: workspace, screen: screen, pane: pane, surface: daemonSurface,
                                                                              index: 0, entity: entity, clientTransactionID: transaction)))
        }
        _ = store.apply(batch: [added(nil, sequence: 1)])
        #expect(surfaces() == [tab.surface], "the raw tab took the stand-in's place before its create was named: \(surfaces())")

        // The copy with the create's transaction: the daemon's tab takes the stand-in over, alone.
        _ = store.apply(batch: [added(transaction, sequence: 2)])
        #expect(surfaces() == [daemonSurface])
    }

    @Test func refusedNewWorkspaceLeavesNothing() {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let transaction = ClientTransactionID.generate()
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: "2", tab: Self.page()), index: nil),
                     transaction: transaction)
        store.rejectIntent(transaction)
        #expect(store.workspace(id: key.rawValue) == nil)
        #expect(store.workspaces.map(\.id) == [Self.baseKey.rawValue])
        #expect(store.mirrorViolations.isEmpty)
    }

    // MARK: Cmd-T

    @Test func newTabShowsInItsPaneInTheIntentsTurn() throws {
        let store = Self.store()
        let tab = Self.page()
        store.intend(.createTab(pane: Self.pane, provisional: tab), transaction: .generate())
        let pane = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first?.panes.first)
        #expect(pane.tabs.map(\.surface).last == tab.surface)
        #expect(pane.tabs.count == 2)
    }

    // MARK: Ctrl-` (New Terminal Tab, ctrl-backtick-instant)

    private static func pane(of store: DaemonStore) throws -> PaneModel {
        try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first?.panes.first)
    }

    private static func tabAdded(_ surface: SurfaceID, terminal: TerminalID, sequence: UInt64) -> DaemonEventEnvelope {
        let entity = TabSnapshot(surface: surface, terminalID: terminal, kind: .pty)
        return DaemonEventEnvelope(sequence: sequence, event: .tabAdded(TabDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: Self.pane, surface: surface,
            index: 1, entity: entity, clientTransactionID: nil)))
    }

    @Test func newTerminalTabShowsInItsPaneInTheIntentsTurn() throws {
        let store = Self.store()
        let provisional = ProvisionalTab()
        store.intend(.createTab(pane: Self.pane, provisional: provisional.terminal(.generate(), cwd: "/tmp")), transaction: .generate())
        let pane = try Self.pane(of: store)
        #expect(pane.tabs.map(\.surface) == [SurfaceID(rawValue: 4), provisional.surface])
        #expect(pane.tabs.last?.kind == .pty)
    }

    /// The daemon's `tab-added` (no transaction on `new-tab`) can beat the reply: the tab carrying
    /// the terminal id the stand-in named takes its place in that apply, never beside it.
    @Test func daemonTerminalTabTakesTheStandInsPlaceBeforeTheReply() throws {
        let store = Self.store()
        let provisional = ProvisionalTab(), terminal = TerminalID.generate()
        let transaction = ClientTransactionID.generate()
        store.intend(.createTab(pane: Self.pane, provisional: provisional.terminal(terminal, cwd: nil)), transaction: transaction)
        _ = store.apply(batch: [Self.tabAdded(SurfaceID(rawValue: 7), terminal: terminal, sequence: 1)])
        let pane = try Self.pane(of: store)
        #expect(pane.tabs.map(\.surface) == [SurfaceID(rawValue: 4), SurfaceID(rawValue: 7)], "one new tab, the daemon's")
        // The reply then names the same tab: nothing changes, the intent settles.
        ProvisionalTab.created(transaction, surface: SurfaceID(rawValue: 7), in: store)
        store.noteSettled(transaction, at: 1)
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [SurfaceID(rawValue: 4), SurfaceID(rawValue: 7)])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A resync can bring the tree that holds the created tab before the raw `tab-added` and before
    /// the reply: the tab with the terminal id that the stand-in named takes its place in that
    /// apply too, and the covered event then changes nothing.
    ///
    /// The store applies a tree in one of 2 forms. `wholeTree` false: the store compares the tree
    /// with the last one and applies only the workspaces that changed. `wholeTree` true: the store
    /// cannot vouch for the last tree (after an overflow, or on a new connection) and applies the
    /// tree in full.
    @Test(arguments: [false, true])
    func daemonTerminalTabInASnapshotTakesTheStandInsPlaceBeforeTheReply(wholeTree: Bool) throws {
        let store = Self.store()
        let provisional = ProvisionalTab(), terminal = TerminalID.generate()
        let transaction = ClientTransactionID.generate()
        let base = SurfaceID(rawValue: 4), daemon = SurfaceID(rawValue: 7)
        store.intend(.createTab(pane: Self.pane, provisional: provisional.terminal(terminal, cwd: nil)), transaction: transaction)
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [base, provisional.surface])
        // The tree of a resync at sequence 1: it holds the daemon's tab, and no event named the create.
        var resynced = Self.base
        resynced.screens[0].panes[0].tabs.append(TabSnapshot(surface: daemon, terminalID: terminal, kind: .pty))
        let tree = DaemonTree(workspaceRevision: 2, workspaces: [resynced])
        if wholeTree { store.snapshotMemo.reset() }
        #expect((store.incrementalDiff(tree, diff: nil) == nil) == wholeTree, "the form that the store takes for this tree")
        store.apply(snapshot: tree)
        store.snapshotBarrier = 1
        store.advanceAppliedSequence(to: 1)
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [base, daemon], "after the tree: one new tab, the daemon's")
        // The raw `tab-added` that the tree covers: no transaction, not above the barrier.
        _ = store.apply(batch: [Self.tabAdded(daemon, terminal: terminal, sequence: 1)])
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [base, daemon], "after the covered event: one new tab, the daemon's")
        // The reply, in the order of the app: its sequence first, then the tab that it names. The
        // reply names the same tab: nothing changes, and the intent settles when the store is at
        // that sequence.
        store.noteSettled(transaction, at: 2)
        ProvisionalTab.created(transaction, surface: daemon, in: store)
        store.advanceAppliedSequence(to: 2)
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [base, daemon])
        #expect(store.pendingIntents.isEmpty)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// Two creates wait and one tree holds the tabs of the two: each stand-in gives way to the tab
    /// with its own terminal id, in the tree's order.
    @Test func daemonTerminalTabsOfTwoCreatesInASnapshotEachTakeTheirStandInsPlace() throws {
        let store = Self.store()
        let first = ProvisionalTab(), second = ProvisionalTab()
        let terminalA = TerminalID.generate(), terminalB = TerminalID.generate()
        let base = SurfaceID(rawValue: 4), daemonA = SurfaceID(rawValue: 7), daemonB = SurfaceID(rawValue: 8)
        store.intend(.createTab(pane: Self.pane, provisional: first.terminal(terminalA, cwd: nil)), transaction: .generate())
        store.intend(.createTab(pane: Self.pane, provisional: second.terminal(terminalB, cwd: nil)), transaction: .generate())
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [base, first.surface, second.surface])
        var resynced = Self.base
        resynced.screens[0].panes[0].tabs.append(TabSnapshot(surface: daemonA, terminalID: terminalA, kind: .pty))
        resynced.screens[0].panes[0].tabs.append(TabSnapshot(surface: daemonB, terminalID: terminalB, kind: .pty))
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [resynced]))
        store.snapshotBarrier = 1
        store.advanceAppliedSequence(to: 1)
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [base, daemonA, daemonB], "after the tree: two new tabs, the daemon's")
        // The pane's list is the same for a crossed pair: the store's own word says which tab each stand-in became.
        #expect(store.intentLog.replacement(ofStandIn: first.id) == daemonA, "the first stand-in became the tab with its terminal id")
        #expect(store.intentLog.replacement(ofStandIn: second.id) == daemonB, "the second stand-in became the tab with its terminal id")
        #expect(store.pendingIntents.count == 2, "no reply came: the two creates still wait")
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The person closed the stand-in before the daemon made the tab, and a resync then brings the
    /// tree that holds that tab: the tab never shows, and the store asks for its close one time, on
    /// the tree's word. The covered event and the reply then ask for no second close.
    @Test func daemonTerminalTabInASnapshotOfACancelledCreateIsHiddenAndClosedOnce() throws {
        let store = Self.store()
        var closed: [SurfaceID] = []
        store.creations.onClose { _, surface in closed.append(surface) }
        let terminal = TerminalID.generate()
        let standIn = ProvisionalTab().terminal(terminal, cwd: nil)
        let transaction = ClientTransactionID.generate()
        let base = SurfaceID(rawValue: 4), daemon = SurfaceID(rawValue: 7)
        store.intend(.createTab(pane: Self.pane, provisional: standIn), transaction: transaction)
        #expect(store.creations.cancel(tab: try #require(standIn.tabResourceID?.rawValue)))
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [base], "the closed stand-in is gone")
        #expect(closed.isEmpty, "nothing names the daemon's tab yet")
        // The tree of a resync at sequence 1: it holds the daemon's tab, and no event named the create.
        var resynced = Self.base
        resynced.screens[0].panes[0].tabs.append(TabSnapshot(surface: daemon, terminalID: terminal, kind: .pty))
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [resynced]))
        store.snapshotBarrier = 1
        store.advanceAppliedSequence(to: 1)
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [base], "after the tree: the closed tab does not show")
        #expect(closed == [daemon], "after the tree: one close, of the daemon's tab")
        // The raw `tab-added` that the tree covers: no transaction, not above the barrier.
        _ = store.apply(batch: [Self.tabAdded(daemon, terminal: terminal, sequence: 1)])
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [base], "after the covered event: the closed tab does not show")
        #expect(closed == [daemon], "after the covered event: no second close")
        // The reply, in the order of the app. The records still hold the daemon's tab (no event
        // closed it), so the create stays in the log and keeps the tab hidden.
        store.noteSettled(transaction, at: 2)
        ProvisionalTab.created(transaction, surface: daemon, in: store)
        store.advanceAppliedSequence(to: 2)
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [base], "after the reply: the closed tab does not show")
        #expect(closed == [daemon], "after the reply: no second close")
        #expect(store.pendingIntents.count == 1, "the create stays until the records lose its tab")
        #expect(store.mirrorViolations.isEmpty)
    }

    /// Another terminal's tab (a CLI `new-tab` racing the key) is not the stand-in's.
    @Test func anotherTerminalTabShowsBesideTheStandIn() throws {
        let store = Self.store()
        let provisional = ProvisionalTab()
        store.intend(.createTab(pane: Self.pane, provisional: provisional.terminal(.generate(), cwd: nil)), transaction: .generate())
        _ = store.apply(batch: [Self.tabAdded(SurfaceID(rawValue: 7), terminal: .generate(), sequence: 1)])
        #expect(Set(try Self.pane(of: store).tabs.map(\.surface)) == [SurfaceID(rawValue: 4), SurfaceID(rawValue: 7), provisional.surface])
    }

    @Test func refusedNewTerminalTabLeavesNothing() throws {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(.createTab(pane: Self.pane, provisional: ProvisionalTab().terminal(.generate(), cwd: nil)), transaction: transaction)
        store.rejectIntent(transaction)
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [SurfaceID(rawValue: 4)])
        #expect(store.mirrorViolations.isEmpty)
    }

    // MARK: Cmd-D, Cmd-Shift-D

    @Test(arguments: [SplitDirection.right, .down])
    func splitShowsItsPaneInTheIntentsTurn(direction: SplitDirection) throws {
        let store = Self.store()
        let provisional = ProvisionalPane()
        store.intend(.splitPane(pane: Self.pane, direction: direction, ratio: 0.5, provisional: provisional), transaction: .generate())
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(screen.panes.map(\.handle) == [Self.pane, provisional.handle])
        #expect(screen.layout.paneIDs.contains(provisional.handle))
    }

    // MARK: New Column

    /// New Column (`new-pane-right` with client-minted ids): in the intent's turn the screen shows
    /// a new scrolling column after the pane's, holding the provisional pane, at the requested
    /// width, and the split-tree screen's lone column stays full width (R3b: a new column never
    /// resizes the columns there).
    @Test func newColumnShowsItsColumnInTheIntentsTurn() throws {
        let store = Self.store()
        let provisional = ProvisionalPane(columnWidth: 0.5)
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: provisional), transaction: .generate())
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(screen.panes.map(\.handle) == [Self.pane, provisional.handle])
        #expect(screen.layout.paneIDs.contains(provisional.handle))
        #expect(screen.columns.map(\.layout.paneIDs) == [[Self.pane], [provisional.handle]], "New Column split the pane instead")
        #expect(screen.columns.map(\.width) == [1, 0.5])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// New Column on a screen that has columns: the new column goes right after the pane's
    /// column, the others keep their place and width.
    @Test func newColumnGoesAfterThePanesColumn() throws {
        let store = DaemonStore()
        let other = PaneID(rawValue: 5)
        var tree = Self.base
        tree.screens[0].layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(Self.pane), b: .leaf(other))
        tree.screens[0].panes.append(PaneSnapshot(id: other, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 6))]))
        tree.screens[0].columns = [ColumnSnapshot(id: ColumnID(rawValue: 1), width: 0.5, layout: .leaf(Self.pane)),
                                   ColumnSnapshot(id: ColumnID(rawValue: 2), width: 0.5, layout: .leaf(other))]
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [tree]))
        let provisional = ProvisionalPane(columnWidth: 0.4)
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: provisional), transaction: transaction)
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(screen.columns.map(\.layout.paneIDs) == [[Self.pane], [provisional.handle], [other]])
        #expect(screen.columns.map(\.width) == [0.5, 0.4, 0.5])
        // A refusal takes the column out exactly.
        store.rejectIntent(transaction)
        let after = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(after.columns.map(\.layout.paneIDs) == [[Self.pane], [other]])
        #expect(after.panes.map(\.handle) == [Self.pane, other])
        #expect(store.mirrorViolations.isEmpty)
    }

    // MARK: New Row

    /// New Row (`new-row` with client-minted ids, `row-client-keys-v1`): in the intent's turn a
    /// split-tree screen shows one column of two rows, the tree at full height and the new
    /// pane's row below at its height; a refusal takes it out exactly.
    @Test func newRowShowsItsRowInTheIntentsTurn() throws {
        let store = Self.store()
        let provisional = ProvisionalPane(rowHeight: 400)
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .down, ratio: 0.5, provisional: provisional), transaction: transaction)
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(screen.panes.map(\.handle) == [Self.pane, provisional.handle])
        #expect(screen.layout.paneIDs.contains(provisional.handle))
        let column = try #require(screen.columns.first)
        #expect(screen.columns.count == 1)
        #expect(column.rows.map(\.layout.paneIDs) == [[Self.pane], [provisional.handle]], "New Row split the pane instead")
        #expect(column.rows.map(\.height) == [1000, 400])
        store.rejectIntent(transaction)
        let after = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(after.columns.isEmpty && after.panes.map(\.handle) == [Self.pane])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// New Row in a column that has rows: the new row goes right below the pane's row.
    @Test func newRowGoesBelowThePanesRow() throws {
        let store = DaemonStore()
        let other = PaneID(rawValue: 5)
        var tree = Self.base
        tree.screens[0].layout = .split(id: nil, resourceID: nil, direction: .down, ratio: 0.5, a: .leaf(Self.pane), b: .leaf(other))
        tree.screens[0].panes.append(PaneSnapshot(id: other, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 6))]))
        tree.screens[0].columns = [ColumnSnapshot(id: ColumnID(rawValue: 1), width: 1, layout: tree.screens[0].layout,
                                                  rows: [RowSnapshot(id: RowID(rawValue: 1), height: 500, layout: .leaf(Self.pane)),
                                                         RowSnapshot(id: RowID(rawValue: 2), height: 500, layout: .leaf(other))])]
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [tree]))
        let provisional = ProvisionalPane(rowHeight: 300)
        store.intend(.splitPane(pane: Self.pane, direction: .down, ratio: 0.5, provisional: provisional), transaction: .generate())
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        let column = try #require(screen.columns.first)
        #expect(column.rows.map(\.layout.paneIDs) == [[Self.pane], [provisional.handle], [other]])
        #expect(column.rows.map(\.height) == [500, 300, 500])
        #expect(column.layout.paneIDs.contains(provisional.handle))
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A fast second New Column (Cmd-Shift-N twice): the second press targets the first's stand-in,
    /// which the daemon's pane then takes over under a new handle. The second column keeps showing
    /// right after it, and its command goes to the daemon's pane (`daemonHandle(showing:)`), never to
    /// the stand-in's handle, which the daemon does not know.
    @Test func newColumnOnAPendingColumnFollowsItsDaemonPane() throws {
        let store = Self.store()
        let first = ProvisionalPane(columnWidth: 0.5)
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: first), transaction: .generate())
        let second = ProvisionalPane(columnWidth: 0.5)
        store.intend(.splitPane(pane: first.handle, direction: .right, ratio: 0.5, provisional: second), transaction: .generate())
        #expect(store.daemonHandle(showing: first.handle) == nil, "the first column has no daemon pane yet")
        let daemon = PaneID(rawValue: 9)
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneAdded(PaneDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: daemon, index: 1,
            entity: PaneSnapshot(id: daemon, resourceID: ResourceID(rawValue: first.paneID),
                                 tabs: [TabSnapshot(surface: SurfaceID(rawValue: 7))]),
            clientTransactionID: nil)))])
        #expect(store.daemonHandle(showing: first.handle) == daemon)
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(screen.panes.map(\.handle) == [Self.pane, daemon, second.handle], "the second column left once the first was confirmed")
        #expect(screen.columns.last?.layout.paneIDs == [second.handle])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A conversation tab's split (`conversation-tab-split-v1`): the daemon's `pane-added`, carrying
    /// the split's transaction, names the split's tab before the `layout-changed` that places the
    /// pane. In between the screen stays split, the daemon's pane where the provisional one was
    /// (cx-ry0y); it showed unsplit for a turn, and the window built the new pane again.
    @Test func conversationSplitStaysSplitFromItsPaneUntilItsLayout() throws {
        let store = Self.store()
        let provisional = ProvisionalPane(holding: Self.page())
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: provisional), transaction: transaction)
        let daemon = PaneID(rawValue: 9)
        let entity = PaneSnapshot(id: daemon, resourceID: ResourceID(rawValue: provisional.paneID),
                                  tabs: [TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .conversation)])
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneAdded(PaneDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: daemon, index: 1,
            entity: entity, clientTransactionID: transaction)))])
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(screen.panes.map(\.handle) == [Self.pane, daemon])
        #expect(screen.layout.paneIDs.contains(daemon), "the screen showed unsplit before the daemon's layout placed the pane")
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The split's tab confirmed with its pane, then moved out (tab-drag-v1) and the daemon's pane
    /// closed before any layout placed it: the split has no pane left to place, so the screen
    /// shows the daemon's records, never the provisional pane back beside the moved tab.
    @Test func conversationSplitShowsNoPaneOnceTheDaemonsPaneCloses() throws {
        let store = Self.store()
        let provisional = ProvisionalPane(holding: Self.page())
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: provisional), transaction: transaction)
        let daemon = PaneID(rawValue: 9), surface = SurfaceID(rawValue: 7)
        let tab = TabSnapshot(surface: surface, kind: .conversation)
        let place = (workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2))
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneAdded(PaneDelta(
            workspace: place.workspace, screen: place.screen, pane: daemon, index: 1,
            entity: PaneSnapshot(id: daemon, resourceID: ResourceID(rawValue: provisional.paneID), tabs: [tab]),
            clientTransactionID: transaction)))])
        _ = store.apply(batch: [
            DaemonEventEnvelope(sequence: 2, event: .tabChanged(TabDelta(
                workspace: place.workspace, screen: place.screen, pane: Self.pane, surface: surface, index: 1, entity: tab,
                clientTransactionID: nil))),
            DaemonEventEnvelope(sequence: 3, event: .paneClosed(PaneDelta(
                workspace: place.workspace, screen: place.screen, pane: daemon, index: nil,
                entity: PaneSnapshot(id: daemon, tabs: []), clientTransactionID: nil))),
        ])
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(screen.panes.map(\.handle) == [Self.pane], "the provisional pane came back after the daemon's pane closed")
        #expect(screen.layout.paneIDs == [Self.pane])
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [SurfaceID(rawValue: 4), surface])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The same split, then the moved tab closes: the intent settled when the daemon's pane closed
    /// (its creation was confirmed and nothing is left to place), so the provisional pane never
    /// comes back once the moved tab, the last thing that kept it hidden, is gone.
    @Test func conversationSplitSettlesOnceTheDaemonsPaneCloses() throws {
        let store = Self.store()
        let provisional = ProvisionalPane(holding: Self.page())
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: provisional), transaction: transaction)
        let daemon = PaneID(rawValue: 9), surface = SurfaceID(rawValue: 7)
        let tab = TabSnapshot(surface: surface, kind: .conversation)
        let place = (workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2))
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneAdded(PaneDelta(
            workspace: place.workspace, screen: place.screen, pane: daemon, index: 1,
            entity: PaneSnapshot(id: daemon, resourceID: ResourceID(rawValue: provisional.paneID), tabs: [tab]),
            clientTransactionID: transaction)))])
        _ = store.apply(batch: [
            DaemonEventEnvelope(sequence: 2, event: .tabChanged(TabDelta(
                workspace: place.workspace, screen: place.screen, pane: Self.pane, surface: surface, index: 1, entity: tab,
                clientTransactionID: nil))),
            DaemonEventEnvelope(sequence: 3, event: .paneClosed(PaneDelta(
                workspace: place.workspace, screen: place.screen, pane: daemon, index: nil,
                entity: PaneSnapshot(id: daemon, tabs: []), clientTransactionID: nil))),
        ])
        #expect(store.pendingIntents.isEmpty, "the split lingered after the daemon's pane closed")
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 4, event: .tabClosed(TabDelta(
            workspace: place.workspace, screen: place.screen, pane: Self.pane, surface: surface, index: nil, entity: tab,
            clientTransactionID: nil)))])
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(screen.panes.map(\.handle) == [Self.pane], "the provisional pane came back once the moved tab closed")
        #expect(screen.layout.paneIDs == [Self.pane])
        #expect(try Self.pane(of: store).tabs.map(\.surface) == [SurfaceID(rawValue: 4)])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A terminal split whose reply settled before its pane arrived keeps showing split until the
    /// daemon's layout places the pane (cx-ry0y)...
    @Test func terminalSplitSettledBeforeItsPaneStaysSplit() throws {
        let store = Self.store()
        let provisional = ProvisionalPane()
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .down, ratio: 0.5, provisional: provisional), transaction: transaction)
        store.noteSettled(transaction, at: 1)
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .tabChanged(TabDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: Self.pane,
            surface: SurfaceID(rawValue: 4), index: 0, entity: TabSnapshot(surface: SurfaceID(rawValue: 4)),
            clientTransactionID: nil)))])
        #expect(store.pendingIntents.count == 1, "the split settled before the daemon reported its pane")
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(screen.panes.map(\.handle) == [Self.pane, provisional.handle])
        #expect(screen.layout.paneIDs.contains(provisional.handle))
        // The terminal stand-in's tab id is the split's client-minted `tab_…`, not a provisional
        // id: the overlay conservation count still knows it as the overlay's own tab.
        #expect(store.mirrorViolations.isEmpty)
    }

    /// ...and once the daemon's pane arrived and closed before any layout placed it, the split has
    /// nothing left to wait for: it settles, and the provisional pane does not come back.
    @Test func terminalSplitWhosePaneClosesBeforeItsLayoutSettles() throws {
        let store = Self.store()
        let provisional = ProvisionalPane()
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .down, ratio: 0.5, provisional: provisional), transaction: transaction)
        store.noteSettled(transaction, at: 1)
        let daemon = PaneID(rawValue: 9)
        let place = (workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2))
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneAdded(PaneDelta(
            workspace: place.workspace, screen: place.screen, pane: daemon, index: 1,
            entity: PaneSnapshot(id: daemon, resourceID: ResourceID(rawValue: provisional.paneID),
                                 tabs: [TabSnapshot(surface: SurfaceID(rawValue: 7))]),
            clientTransactionID: nil)))])
        #expect(store.pendingIntents.count == 1, "the split settled before the daemon's layout placed its pane")
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: .paneClosed(PaneDelta(
            workspace: place.workspace, screen: place.screen, pane: daemon, index: nil,
            entity: PaneSnapshot(id: daemon, tabs: []), clientTransactionID: nil)))])
        #expect(store.pendingIntents.isEmpty, "the split lingered after the daemon's pane closed")
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(screen.panes.map(\.handle) == [Self.pane], "the provisional pane came back after the daemon's pane closed")
        #expect(screen.layout.paneIDs == [Self.pane])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A terminal split not yet replied to whose daemon pane reaches the records only through a
    /// resync snapshot, then closes before any layout placed it: as on the event path, the split
    /// has nothing left to place, so the provisional pane does not come back, and the reply
    /// settles it at once.
    @Test func terminalSplitWhosePaneCameInASnapshotAndClosesSettles() throws {
        let store = Self.store()
        let provisional = ProvisionalPane()
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .down, ratio: 0.5, provisional: provisional), transaction: transaction)
        let daemon = PaneID(rawValue: 9)
        var resynced = Self.base
        resynced.screens[0].panes.append(PaneSnapshot(id: daemon, resourceID: ResourceID(rawValue: provisional.paneID),
                                                      tabs: [TabSnapshot(surface: SurfaceID(rawValue: 7))]))
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [resynced]))
        #expect(store.pendingIntents.count == 1, "the snapshot settled a split that was not replied to")
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneClosed(PaneDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: daemon, index: nil,
            entity: PaneSnapshot(id: daemon, tabs: []), clientTransactionID: nil)))])
        let screen = try #require(store.workspace(id: Self.baseKey.rawValue)?.screens.first)
        #expect(screen.panes.map(\.handle) == [Self.pane], "the provisional pane came back after the daemon's pane closed")
        #expect(screen.layout.paneIDs == [Self.pane])
        store.noteSettled(transaction, at: 1)
        #expect(store.pendingIntents.isEmpty, "the split lingered after the daemon's pane closed")
        #expect(store.mirrorViolations.isEmpty)
    }
}
