#if os(iOS)
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

@Suite("Workspace list refresh coordinator")
@MainActor
struct WorkspaceListRefreshCoordinatorTests {
    @Test("uses the native refresh control without writing table insets or bounce")
    func usesNativeRefreshControlWithoutWritingInsetsOrBounce() throws {
        let configuration = makeConfiguration(refresh: {})
        let tableView = makeTableView()
        tableView.contentInset = UIEdgeInsets(top: 8, left: 1, bottom: 2, right: 3)
        tableView.verticalScrollIndicatorInsets = UIEdgeInsets(
            top: 9,
            left: 4,
            bottom: 5,
            right: 6
        )
        tableView.alwaysBounceVertical = false
        let originalContentInset = tableView.contentInset
        let originalIndicatorInsets = tableView.verticalScrollIndicatorInsets
        let originalBounces = tableView.bounces
        let coordinator = WorkspaceListTableCoordinator(configuration: configuration)

        coordinator.attach(to: tableView)
        coordinator.update(configuration: configuration, in: tableView)

        _ = try #require(tableView.refreshControl)
        #expect(tableView.contentInset == originalContentInset)
        #expect(tableView.verticalScrollIndicatorInsets == originalIndicatorInsets)
        #expect(tableView.alwaysBounceVertical)
        #expect(tableView.bounces == originalBounces)
    }

    @Test("removing refresh leaves table geometry untouched")
    func removingRefreshDoesNotChangeGeometry() {
        let configuration = makeConfiguration(refresh: {})
        let tableView = makeTableView()
        tableView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 7, right: 0)
        let originalContentInset = tableView.contentInset
        let originalBounces = tableView.bounces
        let coordinator = WorkspaceListTableCoordinator(configuration: configuration)
        coordinator.attach(to: tableView)
        coordinator.update(configuration: configuration, in: tableView)

        coordinator.update(
            configuration: makeConfiguration(refresh: nil),
            in: tableView
        )
        #expect(tableView.refreshControl == nil)
        #expect(tableView.contentInset == originalContentInset)
        #expect(tableView.bounces == originalBounces)
    }

    private func makeTableView() -> WorkspaceListUITableView {
        let tableView = WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            style: .plain
        )
        tableView.register(
            UITableViewCell.self,
            forCellReuseIdentifier: "WorkspaceListTableCell"
        )
        return tableView
    }

    private func makeConfiguration(
        refresh: (@Sendable () async -> Void)?
    ) -> WorkspaceListTable {
        WorkspaceListTable(
            items: [],
            workspacesByID: [:],
            groupsByID: [:],
            groupHasUnreadByID: [:],
            filter: .all,
            selectedWorkspaceID: nil,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            previewLineLimit: 1,
            unreadIndicatorLeftShift: 0,
            profilePictureLeftShift: 0,
            profilePictureSize: 28,
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
            refresh: refresh
        )
    }
}

#endif
