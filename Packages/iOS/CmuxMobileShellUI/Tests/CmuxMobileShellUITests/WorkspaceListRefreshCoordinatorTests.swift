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

    @Test("ends native refresh only after the refreshed snapshot applies")
    func endsRefreshAfterSnapshotApplication() async throws {
        let gate = RefreshActionGate()
        let refreshCompleted = MainActorSignal()
        var completionGeneration: UInt64 = 0
        let configuration = makeConfiguration(
            refreshDidComplete: {
                completionGeneration &+= 1
                refreshCompleted.signal()
            }
        ) {
            await gate.waitForRelease()
        }
        let tableView = makeTableView()
        let coordinator = WorkspaceListTableCoordinator(configuration: configuration)
        coordinator.attach(to: tableView)
        coordinator.update(configuration: configuration, in: tableView)
        _ = try #require(tableView.refreshControl)
        let refreshControl = RecordingRefreshControl()
        tableView.refreshControl = refreshControl

        refreshControl.beginRefreshing()
        _ = coordinator.perform(
            NSSelectorFromString("refreshRequested:"),
            with: refreshControl
        )
        await gate.waitUntilStarted()
        await gate.release()
        await refreshCompleted.wait()

        #expect(refreshControl.endCount == 0)

        coordinator.update(
            configuration: makeConfiguration(
                refreshCompletionGeneration: completionGeneration,
                refresh: {}
            ),
            in: tableView
        )
        await refreshControl.waitUntilEndCount(1)
        #expect(refreshControl.endCount == 1)
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
        refreshCompletionGeneration: UInt64 = 0,
        refreshDidComplete: @escaping @MainActor () -> Void = {},
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
            refresh: refresh,
            refreshCompletionGeneration: refreshCompletionGeneration,
            refreshDidComplete: refreshDidComplete
        )
    }

}

@MainActor
private final class RecordingRefreshControl: UIRefreshControl {
    private(set) var endCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    override func endRefreshing() {
        endCount += 1
        super.endRefreshing()
        let ready = waiters.filter { $0.count <= endCount }
        waiters.removeAll { $0.count <= endCount }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitUntilEndCount(_ count: Int) async {
        guard endCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private actor RefreshActionGate {
    private var didStart = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
private final class MainActorSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

#endif
