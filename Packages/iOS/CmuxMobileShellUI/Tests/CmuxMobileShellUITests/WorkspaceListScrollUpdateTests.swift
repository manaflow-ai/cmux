#if os(iOS)
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceListScrollUpdateTests {
    @Test func liveSnapshotWaitsForDirectionReversalToFinish() {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let tableView = WorkspaceListUITableView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        coordinator.attach(to: tableView)
        coordinator.update(configuration: initial, in: tableView)
        #expect(tableView.numberOfRows(inSection: 0) == 1)

        let scrollDelegate: any UIScrollViewDelegate = coordinator
        scrollDelegate.scrollViewWillBeginDragging?(tableView)
        scrollDelegate.scrollViewDidEndDragging?(tableView, willDecelerate: true)

        let liveUpdate = configuration(workspaceIDs: ["workspace-1", "workspace-2"])
        coordinator.update(configuration: liveUpdate, in: tableView)
        #expect(
            tableView.numberOfRows(inSection: 0) == 1,
            "A live workspace update must not mutate the table while the first flick is decelerating."
        )

        scrollDelegate.scrollViewWillBeginDragging?(tableView)
        #expect(
            tableView.numberOfRows(inSection: 0) == 1,
            "Grabbing a decelerating list to reverse direction must keep the pending snapshot staged."
        )

        let latestUpdate = configuration(
            workspaceIDs: ["workspace-1", "workspace-2", "workspace-3"]
        )
        coordinator.update(configuration: latestUpdate, in: tableView)
        #expect(
            tableView.numberOfRows(inSection: 0) == 1,
            "Updates received during the reverse drag must remain staged."
        )

        scrollDelegate.scrollViewDidEndDragging?(tableView, willDecelerate: false)
        #expect(
            tableView.numberOfRows(inSection: 0) == 3,
            "The newest staged snapshot must apply when the reversing gesture finishes without momentum."
        )
    }

    @Test func liveSnapshotAppliesAfterDecelerationEnds() {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let tableView = WorkspaceListUITableView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        coordinator.attach(to: tableView)
        coordinator.update(configuration: initial, in: tableView)

        let scrollDelegate: any UIScrollViewDelegate = coordinator
        scrollDelegate.scrollViewWillBeginDragging?(tableView)
        scrollDelegate.scrollViewDidEndDragging?(tableView, willDecelerate: true)
        coordinator.update(
            configuration: configuration(workspaceIDs: ["workspace-1", "workspace-2"]),
            in: tableView
        )

        scrollDelegate.scrollViewDidEndDecelerating?(tableView)
        #expect(
            tableView.numberOfRows(inSection: 0) == 2,
            "The staged snapshot must apply after uninterrupted momentum ends."
        )
    }

    private func configuration(workspaceIDs: [String]) -> WorkspaceListTable {
        let workspaces = workspaceIDs.map { rawID in
            MobileWorkspacePreview(
                id: .init(rawValue: rawID),
                name: rawID,
                terminals: []
            )
        }
        return WorkspaceListTable(
            items: workspaces.map { .workspace($0.id, indented: false) },
            workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
            groupsByID: [:],
            groupHasUnreadByID: [:],
            filter: .all,
            selectedWorkspaceID: nil,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            previewLineLimit: 2,
            unreadIndicatorLeftShift: 0,
            profilePictureLeftShift: 0,
            profilePictureSize: 32,
            connectionStatus: .connected,
            connectionRequiresReauth: false,
            connectionRecoveryFailed: false,
            isRecoveringConnection: false,
            connectionError: nil,
            host: "Test Mac",
            isInitialConnectionLoading: false,
            initialConnectionTitle: nil,
            initialConnectionDescription: nil,
            enablesReorder: false,
            moveRows: nil,
            selectWorkspace: { _ in },
            requestWorkspaceClose: nil,
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
            retryConnectionRecovery: nil,
            signOut: nil,
            retryInitialConnection: nil,
            showAddDevice: nil,
            reconnect: nil,
            refresh: nil
        )
    }
}
#endif
