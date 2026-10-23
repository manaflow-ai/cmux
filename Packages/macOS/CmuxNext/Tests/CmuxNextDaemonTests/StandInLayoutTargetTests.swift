import Foundation
import Testing
@testable import CmuxNextDaemon

/// Gestures on a pending New Column's or New Row's stand-in (review 2 of PL-motion-core): a row
/// edge dragged right after New Row, or a tab dropped after a column New Column just made, named
/// the stand-in's column and row ids. The daemon refused them ("unknown pane", `ColumnNotFound`,
/// `row-set-stale`), the intent was rejected and the drag snapped back during the create's motion.
/// Now the drag shows on whichever column and rows show the create (the daemon's once placed) and
/// its send names the daemon's ids (``DaemonStore/daemonColumnTarget(column:heights:)``).
@MainActor
struct StandInLayoutTargetTests {
    private static let pane = PaneID(rawValue: 3)
    private static let column = ColumnID(rawValue: 1)
    private static let baseKey = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000002")
    private static let base = WorkspaceSnapshot(
        id: WorkspaceHandle(rawValue: 1), key: baseKey, name: "1",
        screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                 columns: [ColumnSnapshot(id: column, width: 1, layout: .leaf(pane))],
                                 panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])])])

    /// One workspace with one screen holding one daemon column of one pane.
    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [base]))
        return store
    }

    private static func rows(of store: DaemonStore) throws -> [RowSnapshot] {
        let screen = try #require(store.workspace(id: baseKey.rawValue)?.screens.first)
        return try #require(screen.columns.first { $0.layout.paneIDs.contains(pane) }).rows
    }

    /// New Row, then its row edge dragged before the daemon made the row: the drag shows on the
    /// stand-in rows, its send waits for the daemon's rows and names them, and once the daemon's
    /// layout replaces the stand-in rows the drag still shows on them (no snap-back frame).
    @Test func aRowEdgeDraggedOnAPendingNewRowNamesTheDaemonRowsAndHolds() async throws {
        let store = Self.store()
        let provisional = ProvisionalPane(rowHeight: 500)
        let create = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .down, ratio: 0.5, provisional: provisional), transaction: create)
        let row = try #require(provisional.row)
        #expect(try Self.rows(of: store).map(\.id) == [row.firstHandle, row.handle])

        // The drag's release, named in the stand-in's ids, shows at once.
        let heights = [RowHeightValue(row: row.firstHandle, height: 600), RowHeightValue(row: row.handle, height: 400)]
        store.intend(.setRowHeights(column: Self.column, heights: heights), transaction: .generate())
        #expect(try Self.rows(of: store).map(\.height) == [600, 400])

        let target = Task { try await store.daemonColumnTarget(column: Self.column, heights: heights) }
        await Task.yield()
        #expect(store.standInWaiters.count == 1, "the row heights went out naming the stand-in's rows")

        // The daemon's New Row: its pane under the stand-in's public id, in two daemon rows.
        store.noteSettledAtNextSnapshot(create)
        let rowPane = PaneID(rawValue: 9)
        var tree = Self.base
        let rows = [RowSnapshot(id: RowID(rawValue: 21), height: 1000, layout: .leaf(Self.pane)),
                    RowSnapshot(id: RowID(rawValue: 22), height: 500, layout: .leaf(rowPane))]
        let chain = LayoutNode.split(id: nil, resourceID: nil, direction: .down, ratio: 0.5, a: .leaf(Self.pane), b: .leaf(rowPane))
        tree.screens[0].layout = chain
        tree.screens[0].columns = [ColumnSnapshot(id: Self.column, width: 1, layout: chain, rows: rows)]
        tree.screens[0].panes.append(PaneSnapshot(id: rowPane, resourceID: ResourceID(rawValue: provisional.paneID),
                                                  tabs: [TabSnapshot(surface: SurfaceID(rawValue: 7))]))
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [tree]))

        #expect(try Self.rows(of: store).map(\.id) == [RowID(rawValue: 21), RowID(rawValue: 22)])
        #expect(try Self.rows(of: store).map(\.height) == [600, 400], "the drag snapped back when the daemon's rows arrived")
        let resolved = try await target.value
        #expect(resolved.column == Self.column)
        #expect(resolved.heights == [RowHeightValue(row: RowID(rawValue: 21), height: 600),
                                     RowHeightValue(row: RowID(rawValue: 22), height: 400)])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// New Column, then a tab dropped after the new column before the daemon made it: the move's
    /// `afterColumn` names the daemon's column, never the stand-in column.
    @Test func aDropAfterAPendingNewColumnNamesTheDaemonColumn() async throws {
        let store = Self.store()
        let provisional = ProvisionalPane(columnWidth: 0.5, widths: [Self.column: 0.5])
        let create = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .right, ratio: 0.5, provisional: provisional), transaction: create)
        let standInColumn = try #require(provisional.column?.handle)
        #expect(store.isStandIn(column: standInColumn))
        #expect(store.isStandIn(provisional.handle))
        #expect(!store.isStandIn(Self.pane))

        let target = Task { try await store.daemonColumnTarget(column: standInColumn, heights: []) }
        await Task.yield()
        #expect(store.standInWaiters.count == 1)

        store.noteSettledAtNextSnapshot(create)
        let columnPane = PaneID(rawValue: 9)
        var tree = Self.base
        tree.screens[0].layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(Self.pane), b: .leaf(columnPane))
        tree.screens[0].columns = [ColumnSnapshot(id: Self.column, width: 0.5, layout: .leaf(Self.pane)),
                                   ColumnSnapshot(id: ColumnID(rawValue: 5), width: 0.5, layout: .leaf(columnPane))]
        tree.screens[0].panes.append(PaneSnapshot(id: columnPane, resourceID: ResourceID(rawValue: provisional.paneID),
                                                  tabs: [TabSnapshot(surface: SurfaceID(rawValue: 7))]))
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [tree]))
        #expect(try await target.value.column == ColumnID(rawValue: 5))
    }

    /// A row edge dragged on a New Row that the daemon refused: nothing the daemon knows is left
    /// to name, so the send is refused (the drag leaves with its create), never sent.
    @Test func aRowEdgeOnARefusedNewRowIsRefused() async throws {
        let store = Self.store()
        let provisional = ProvisionalPane(rowHeight: 500)
        let create = ClientTransactionID.generate()
        store.intend(.splitPane(pane: Self.pane, direction: .down, ratio: 0.5, provisional: provisional), transaction: create)
        let row = try #require(provisional.row)
        let heights = [RowHeightValue(row: row.firstHandle, height: 600), RowHeightValue(row: row.handle, height: 400)]
        store.intend(.setRowHeights(column: Self.column, heights: heights), transaction: .generate())
        store.rejectIntent(create)
        await #expect(throws: CreateTargetGone.self) { try await store.daemonColumnTarget(column: Self.column, heights: heights) }
        #expect(store.mirrorViolations.isEmpty)
    }
}
