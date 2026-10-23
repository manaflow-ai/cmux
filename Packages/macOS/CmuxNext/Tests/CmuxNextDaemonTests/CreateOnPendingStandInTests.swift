import Foundation
import Testing
@testable import CmuxNextDaemon

/// A create pressed on another create's stand-in while that one is still in flight (review 1 of
/// PL-motion-core): Cmd-D then New Column on its pane, New Column twice, then the first one
/// closed. The second create never sends the stand-in's handle (the daemon refuses it with
/// "unknown pane" and the shown, focused pane goes): at send time it names the first create's
/// daemon pane, waiting for it, or the first create's own anchor once that create was closed or
/// refused (``DaemonStore/daemonTarget(for:)``), and its overlay shows it there too.
@MainActor
struct CreateOnPendingStandInTests {
    private static let pane = PaneID(rawValue: 3)
    private static let place = (workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2))

    private static let baseKey = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001")
    private static let base = WorkspaceSnapshot(
        id: WorkspaceHandle(rawValue: 1), key: baseKey, name: "1",
        screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                 panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])])])

    /// One workspace with one screen and one pane holding one terminal tab.
    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [base]))
        return store
    }

    private static func screen(of store: DaemonStore) throws -> ScreenModel {
        try #require(store.workspace(id: baseKey.rawValue)?.screens.first)
    }

    /// The daemon's `pane-added` of the pane that takes `provisional` over.
    private static func paneAdded(_ handle: PaneID, taking provisional: ProvisionalPane, surface: UInt64,
                                  sequence: UInt64) -> DaemonEventEnvelope {
        DaemonEventEnvelope(sequence: sequence, event: .paneAdded(PaneDelta(
            workspace: place.workspace, screen: place.screen, pane: handle, index: 1,
            entity: PaneSnapshot(id: handle, resourceID: ResourceID(rawValue: provisional.paneID),
                                 tabs: [TabSnapshot(surface: SurfaceID(rawValue: surface))]),
            clientTransactionID: nil)))
    }

    /// Cmd-D, then New Column on the split's stand-in before the daemon made the split: the
    /// column's send waits for the split's daemon pane (its `pane-added`, not its reply) and names
    /// it; through the daemon's layouts of both, both panes stay shown.
    @Test func newColumnOnAPendingSplitNamesItsDaemonPaneAndBothSurvive() async throws {
        let store = Self.store()
        let split = ProvisionalPane()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: split), transaction: .generate())
        let column = ProvisionalPane(columnWidth: 0.5, treeWidth: 0.5)
        store.intend(.splitPane(pane: split.handle, direction: .right, ratio: 0.5, provisional: column), transaction: .generate())
        #expect(try Self.screen(of: store).panes.map(\.handle) == [Self.pane, split.handle, column.handle])
        #expect(store.createTarget(for: split.handle) == .pending)
        #expect(store.createTarget(for: Self.pane) == .pane(Self.pane), "a daemon pane is its own target")

        let target = Task { try await store.daemonTarget(for: split.handle) }
        await Task.yield()
        #expect(store.standInWaiters.count == 1, "the column's send did not wait for the split's daemon pane")

        // The split's pane-added: the column's send goes, naming the daemon's pane.
        let splitPane = PaneID(rawValue: 9)
        _ = store.apply(batch: [Self.paneAdded(splitPane, taking: split, surface: 7, sequence: 1)])
        #expect(try await target.value == splitPane, "the column's send named the stand-in, which the daemon refuses")
        #expect(try Self.screen(of: store).panes.map(\.handle) == [Self.pane, splitPane, column.handle])

        // The daemon's layout of the split, then of the column after it.
        var tree = Self.base
        let splitLayout = LayoutNode.split(id: nil, resourceID: ResourceID(rawValue: split.splitID), direction: .right, ratio: 0.5,
                                           a: .leaf(Self.pane), b: .leaf(splitPane))
        tree.screens[0].layout = splitLayout
        tree.screens[0].panes.append(PaneSnapshot(id: splitPane, resourceID: ResourceID(rawValue: split.paneID),
                                                  tabs: [TabSnapshot(surface: SurfaceID(rawValue: 7))]))
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [tree]))
        var screen = try Self.screen(of: store)
        #expect(screen.panes.map(\.handle) == [Self.pane, splitPane, column.handle], "the column left once the split was placed")
        #expect(screen.columns.map(\.layout.paneIDs) == [[Self.pane, splitPane], [column.handle]])

        let columnPane = PaneID(rawValue: 11)
        tree.screens[0].layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: splitLayout, b: .leaf(columnPane))
        tree.screens[0].columns = [ColumnSnapshot(id: ColumnID(rawValue: 1), width: 0.5, layout: splitLayout),
                                   ColumnSnapshot(id: ColumnID(rawValue: 2), width: 0.5, layout: .leaf(columnPane))]
        tree.screens[0].panes.append(PaneSnapshot(id: columnPane, resourceID: ResourceID(rawValue: column.paneID),
                                                  tabs: [TabSnapshot(surface: SurfaceID(rawValue: 12))]))
        store.apply(snapshot: DaemonTree(workspaceRevision: 3, workspaces: [tree]))
        screen = try Self.screen(of: store)
        #expect(screen.panes.map(\.handle) == [Self.pane, splitPane, columnPane])
        #expect(screen.columns.map(\.layout.paneIDs) == [[Self.pane, splitPane], [columnPane]])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// New Column twice, then the first column closed while both are pending: only the first goes.
    /// The second, made from it, moves to the first one's anchor, in the overlay and at send time,
    /// also once the first one's daemon pane arrives (hidden, its close on the way).
    @Test func closingAPendingColumnKeepsTheColumnMadeFromIt() throws {
        let store = Self.store()
        let first = ProvisionalPane(columnWidth: 0.5, treeWidth: 0.5)
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: first), transaction: .generate())
        let second = ProvisionalPane(columnWidth: 0.5)
        store.intend(.splitPane(pane: first.handle, direction: .right, ratio: 0.5, provisional: second), transaction: .generate())
        #expect(store.creations.cancel(pane: first.handle))

        var screen = try Self.screen(of: store)
        #expect(screen.panes.map(\.handle) == [Self.pane, second.handle], "closing the first column took the second with it")
        #expect(screen.columns.map(\.layout.paneIDs) == [[Self.pane], [second.handle]])
        #expect(store.createTarget(for: first.handle) == .pane(Self.pane), "the second column's send names the closed stand-in")

        _ = store.apply(batch: [Self.paneAdded(PaneID(rawValue: 9), taking: first, surface: 7, sequence: 1)])
        screen = try Self.screen(of: store)
        #expect(screen.panes.map(\.handle) == [Self.pane, second.handle], "the closed column's daemon pane showed")
        #expect(screen.columns.last?.layout.paneIDs == [second.handle])
        #expect(store.createTarget(for: first.handle) == .pane(Self.pane), "the second column was built on the closed one's pane")
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The first column refused: the second, made from it, goes to its anchor.
    @Test func aRefusedColumnHandsTheColumnMadeFromItToItsAnchor() throws {
        let store = Self.store()
        let first = ProvisionalPane(columnWidth: 0.5, treeWidth: 0.5)
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: first), transaction: transaction)
        let second = ProvisionalPane(columnWidth: 0.5)
        store.intend(.splitPane(pane: first.handle, direction: .right, ratio: 0.5, provisional: second), transaction: .generate())
        store.rejectIntent(transaction)

        let screen = try Self.screen(of: store)
        #expect(screen.panes.map(\.handle) == [Self.pane, second.handle])
        #expect(store.createTarget(for: first.handle) == .pane(Self.pane))
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A stand-in the store does not know (never intended, or long gone) is refused, never sent.
    @Test func aCreateOnAnUnknownStandInIsRefused() async {
        let store = Self.store()
        let ghost = ProvisionalPane()
        await #expect(throws: CreateTargetGone.self) { try await store.daemonTarget(for: ghost.handle) }
    }
}
