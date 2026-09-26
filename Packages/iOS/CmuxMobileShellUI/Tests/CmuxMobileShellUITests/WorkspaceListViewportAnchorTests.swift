#if os(iOS)
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

/// Live updates against a laid-out table in a window: the rows the user is
/// looking at must stay on screen where they were, while the table always
/// converges on the latest snapshot.
@MainActor
@Suite struct WorkspaceListViewportAnchorTests {
    private static var fixtureWindows: [UIWindow] = []

    @Test func insertAboveTheViewportKeepsVisibleRowsInPlace() throws {
        let ids = (0..<40).map { "workspace-\($0)" }
        let fixture = Fixture(ids: ids)
        fixture.scroll(toRow: 20)
        let before = fixture.screenY(of: "workspace-20")

        fixture.update(ids: ["new-top"] + ids)

        #expect(fixture.coordinator.lastPayloadApplyRoute == .geometryCommitted)
        #expect(fixture.renderedIDs().first == "new-top")
        #expect(abs(fixture.screenY(of: "workspace-20") - before) < 0.5)
    }

    @Test func removalAboveTheViewportKeepsVisibleRowsInPlace() throws {
        let ids = (0..<40).map { "workspace-\($0)" }
        let fixture = Fixture(ids: ids)
        fixture.scroll(toRow: 20)
        let before = fixture.screenY(of: "workspace-20")

        fixture.update(ids: ids.filter { $0 != "workspace-3" })

        #expect(abs(fixture.screenY(of: "workspace-20") - before) < 0.5)
    }

    @Test func rowShowingLessThanAPixelIsNotTheAnchor() throws {
        let ids = (0..<40).map { "workspace-\($0)" }
        let fixture = Fixture(ids: ids)
        let overlap = try fixture.scroll(row: 19, overlappingTopBy: fixture.pixel / 2)
        try #require(overlap > 0 && overlap < fixture.pixel)
        let before = fixture.screenY(of: "workspace-20")

        // Only anchoring workspace-20 keeps it in place: anchoring the sliver
        // of workspace-19 above it, or no anchor, lets the new row push it down.
        fixture.update(ids: Array(ids[..<20]) + ["new"] + Array(ids[20...]))

        #expect(abs(fixture.screenY(of: "workspace-20") - before) < 0.5)
    }

    @Test func rowShowingOnePixelIsTheAnchor() throws {
        let ids = (0..<40).map { "workspace-\($0)" }
        let fixture = Fixture(ids: ids)
        let overlap = try fixture.scroll(row: 19, overlappingTopBy: fixture.pixel)
        try #require(overlap >= fixture.pixel && overlap < fixture.pixel * 2)
        let before = fixture.screenY(of: "workspace-19")

        // Only anchoring workspace-19 keeps it in place: with no anchor the
        // removal above pulls it up, and anchoring workspace-20 lets the new
        // row between them pull it up.
        fixture.update(
            ids: ids[..<20].filter { $0 != "workspace-3" } + ["new"] + Array(ids[20...])
        )

        #expect(abs(fixture.screenY(of: "workspace-19") - before) < 0.5)
    }

    @Test func notificationMovingAVisibleRowToTheTopKeepsItsNeighborsInPlace() throws {
        let ids = (0..<40).map { "workspace-\($0)" }
        let fixture = Fixture(ids: ids)
        fixture.scroll(toRow: 20)
        let neighborBefore = fixture.screenY(of: "workspace-22")

        // "Reorder on notification" moves the first visible row to the top.
        fixture.update(ids: ["workspace-20"] + ids.filter { $0 != "workspace-20" })

        #expect(fixture.renderedIDs().first == "workspace-20")
        #expect(abs(fixture.screenY(of: "workspace-22") - neighborBefore) < 0.5)
    }

    @Test func listRestingAtTheTopShowsRowsInsertedAboveIt() throws {
        let ids = (0..<40).map { "workspace-\($0)" }
        let fixture = Fixture(ids: ids)
        let topOffset = fixture.tableView.contentOffset.y

        fixture.update(ids: ["new-top"] + ids)

        #expect(fixture.tableView.contentOffset.y == topOffset)
        #expect(fixture.tableView.indexPathsForVisibleRows?.contains(IndexPath(row: 0, section: 0)) == true)
        #expect(fixture.renderedIDs().first == "new-top")
    }

    @Test func offscreenContentIsCurrentWhenItScrollsIntoView() throws {
        let ids = (0..<40).map { "workspace-\($0)" }
        let fixture = Fixture(ids: ids)
        fixture.coordinator.scrollViewWillBeginDragging(fixture.tableView)

        fixture.update(ids: ids, previews: ["workspace-35": "Agent 35 finished"])
        fixture.scroll(toRow: 30)

        let indexPath = try #require(fixture.indexPath(of: "workspace-35"))
        let cell = try #require(fixture.tableView.cellForRow(at: indexPath) as? WorkspaceListTableCell)
        guard case .workspace(let row) = cell.renderedModel else {
            Issue.record("Expected a workspace row")
            return
        }
        #expect(row.content.previewLine == "Agent 35 finished")
    }

    @Test func stableRowsExcludeRowsTheEditScriptMoves() {
        typealias Row = WorkspaceListRenderedRow<String, Bool>
        let rows = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d", "e"].map {
            ($0, Row(model: $0, nativeActions: nil, height: 60))
        })
        let plan = WorkspaceListUpdatePlan(
            renderedIDs: ["a", "b", "c", "d"],
            renderedRows: rows,
            targetIDs: ["c", "a", "b", "d", "e"],
            targetRows: rows
        )
        #expect(plan.structureChanged)
        #expect(plan.stableIDs == ["a", "b", "d"])
    }

    @Test func planSeparatesHeightNeutralContentFromGeometry() {
        typealias Row = WorkspaceListRenderedRow<String, Bool>
        let rendered: [String: Row] = [
            "a": Row(model: "a1", nativeActions: false, height: 60),
            "b": Row(model: "b1", nativeActions: false, height: 60),
            "c": Row(model: "c1", nativeActions: false, height: 60),
        ]
        let target: [String: Row] = [
            "a": Row(model: "a2", nativeActions: false, height: 60),
            "b": Row(model: "b2", nativeActions: false, height: 84),
            "c": Row(model: "c2", nativeActions: true, height: 60),
        ]
        let plan = WorkspaceListUpdatePlan(
            renderedIDs: ["a", "b", "c"],
            renderedRows: rendered,
            targetIDs: ["a", "b", "c"],
            targetRows: target
        )
        #expect(plan.contentOnlyIDs == ["a", "c"])
        #expect(plan.heightChangedIDs == ["b"])
        #expect(plan.nativeActionChangedIDs == ["c"])
        #expect(!plan.structureChanged)
        #expect(plan.needsGeometryCommit)
    }

    @MainActor
    private struct Fixture {
        let coordinator: WorkspaceListTableCoordinator
        let tableView: WorkspaceListUITableView

        init(ids: [String]) {
            coordinator = WorkspaceListTableCoordinator(
                configuration: Self.configuration(ids: ids, previews: [:])
            )
            tableView = WorkspaceListUITableView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let viewController = UIViewController()
            viewController.view.frame = tableView.frame
            viewController.view.addSubview(tableView)
            let window = UIWindow(frame: tableView.frame)
            window.rootViewController = viewController
            window.isHidden = false
            WorkspaceListViewportAnchorTests.fixtureWindows.append(window)
            coordinator.attach(to: tableView)
            tableView.layoutIfNeeded()
        }

        func update(ids: [String], previews: [String: String] = [:]) {
            coordinator.update(
                configuration: Self.configuration(ids: ids, previews: previews),
                in: tableView
            )
            tableView.layoutIfNeeded()
        }

        func scroll(toRow row: Int) {
            tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .top, animated: false)
            tableView.layoutIfNeeded()
        }

        var pixel: CGFloat { 1 / max(tableView.traitCollection.displayScale, 1) }

        /// Scrolls so `row` ends `overlap` points below the top of the viewport,
        /// and returns the overlap measured the way the viewport anchor measures it.
        func scroll(row: Int, overlappingTopBy overlap: CGFloat) throws -> CGFloat {
            let indexPath = IndexPath(row: row, section: 0)
            let topInset = tableView.adjustedContentInset.top
            let maxY = tableView.rectForRow(at: indexPath).maxY
            var offset = maxY - overlap - topInset
            // Rounding can leave the measured overlap an ulp short of the target.
            while maxY - (offset + topInset) < overlap { offset = offset.nextDown }
            tableView.contentOffset.y = offset
            tableView.layoutIfNeeded()
            try #require(tableView.indexPathsForVisibleRows?.contains(indexPath) == true)
            return maxY - (tableView.contentOffset.y + topInset)
        }

        func indexPath(of rawID: String) -> IndexPath? {
            renderedIDs().firstIndex(of: rawID).map { IndexPath(row: $0, section: 0) }
        }

        func screenY(of rawID: String) -> CGFloat {
            guard let indexPath = indexPath(of: rawID) else { return .nan }
            return tableView.rectForRow(at: indexPath).minY - tableView.contentOffset.y
        }

        /// Reads the data source's rows instead of asking it for cells, then
        /// checks each visible cell draws the workspace its row names. This
        /// table is laid out in a window, so UIKit has already dequeued cells
        /// for its rows, and dequeuing a second cell for one of those index
        /// paths throws.
        func renderedIDs() -> [String] {
            let items = coordinator.renderedItems
            #expect(tableView.numberOfRows(inSection: 0) == items.count)
            for indexPath in tableView.indexPathsForVisibleRows ?? [] where items.indices.contains(indexPath.row) {
                let cell = tableView.cellForRow(at: indexPath) as? WorkspaceListTableCell
                guard case .workspace(let row)? = cell?.renderedModel else {
                    Issue.record("Visible row \(indexPath.row) draws no workspace")
                    continue
                }
                // The fixture names each workspace after its ID.
                #expect(row.content.name == items[indexPath.row].workspaceID?.rawValue)
            }
            return items.compactMap { $0.workspaceID?.rawValue }
        }

        static func configuration(ids: [String], previews: [String: String]) -> WorkspaceListTable {
            let workspaces = ids.map { rawID in
                MobileWorkspacePreview(
                    id: .init(rawValue: rawID),
                    name: rawID,
                    previewText: previews[rawID] ?? "Working",
                    terminals: []
                )
            }
            return WorkspaceListTable(
                items: workspaces.map { .workspace($0.id, indented: false) },
                workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
                groupsByID: [:],
                groupUnreadByID: [:],
                filter: .all,
                selectedWorkspaceID: nil,
                navigationStyle: .push,
                wrapWorkspaceTitles: false,
                previewLineLimit: 2,
                unreadIndicatorLeftShift: 0,
                unreadBadgeDiameter: 16,
                connectionStatus: .connected,
                workspaceChangesCapable: false,
                workspaceChangeChipsByWorkspaceID: [:],
                openWorkspaceChanges: nil,
                connectionRequiresReauth: false,
                connectionError: nil,
                host: "Test Mac",
                isInitialConnectionLoading: false,
                initialConnectionTitle: nil,
                initialConnectionDescription: nil,
                enablesReorder: false,
                moveRows: nil,
                canDropIntoGroup: nil,
                dropIntoGroup: nil,
                selectWorkspace: { _ in },
                closeWorkspace: nil,
                setUnread: nil,
                setPinned: nil,
                renameRequest: nil,
                createWorkspaceInGroup: nil,
                renameWorkspaceGroup: nil,
                setGroupPinned: nil,
                ungroupWorkspaceGroup: nil,
                deleteWorkspaceGroup: nil,
                toggleGroupCollapsed: nil,
                showAll: {},
                signOut: nil,
                retryInitialConnection: nil,
                showAddDevice: nil,
                reconnect: nil,
                refresh: nil
            )
        }
    }
}
#endif
