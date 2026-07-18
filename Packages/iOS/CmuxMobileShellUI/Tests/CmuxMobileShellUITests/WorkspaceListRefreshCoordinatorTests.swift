#if os(iOS)
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

@Suite("Workspace list refresh coordinator")
@MainActor
struct WorkspaceListRefreshCoordinatorTests {
    @Test("keeps the refresh control active until a post-refresh snapshot arrives")
    func keepsRefreshControlActiveUntilPostRefreshSnapshot() async {
        let gate = RefreshActionGate()
        let actionReturned = AsyncSignal()
        let configuration = makeConfiguration {
            await gate.waitForRelease()
            await actionReturned.signal()
        }
        let scheduler = ManualRefreshCollapseScheduler()
        let animator = ManualRefreshCollapseAnimator()
        let coordinator = WorkspaceListTableCoordinator(
            configuration: configuration,
            scheduleRefreshCollapse: scheduler.schedule,
            animateRefreshCollapse: animator.animate
        )
        let tableView = WorkspaceListUITableView(frame: .zero, style: .plain)
        let refreshControl = RecordingRefreshControl()
        tableView.refreshControl = refreshControl
        coordinator.attach(to: tableView)
        coordinator.update(configuration: configuration, in: tableView)

        _ = coordinator.perform(
            NSSelectorFromString("refreshRequested:"),
            with: refreshControl
        )
        await gate.waitUntilStarted()
        #expect(refreshControl.endCount == 0)

        await gate.release()
        await actionReturned.wait()
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(
            refreshControl.endCount == 0,
            "Refresh completion must wait for the authoritative post-refresh snapshot."
        )

        let completedConfiguration = makeConfiguration(
            refreshCompletionGeneration: 1,
            refresh: {}
        )
        coordinator.update(configuration: completedConfiguration, in: tableView)
        await scheduler.waitUntilScheduled()
        #expect(scheduler.scheduleCount == 1)
        #expect(
            refreshControl.endCount == 0,
            "The snapshot completion must only schedule the visible collapse."
        )

        scheduler.runNext()
        #expect(refreshControl.endCount == 1)
        #expect(animator.animationCount == 1)
        animator.completeNext()
    }

    @Test("ignores a queued collapse after refresh is removed")
    func ignoresQueuedCollapseAfterRefreshIsRemoved() async {
        let gate = RefreshActionGate()
        let actionReturned = AsyncSignal()
        let configuration = makeConfiguration {
            await gate.waitForRelease()
            await actionReturned.signal()
        }
        let scheduler = ManualRefreshCollapseScheduler()
        let animator = ManualRefreshCollapseAnimator()
        let coordinator = WorkspaceListTableCoordinator(
            configuration: configuration,
            scheduleRefreshCollapse: scheduler.schedule,
            animateRefreshCollapse: animator.animate
        )
        let tableView = WorkspaceListUITableView(frame: .zero, style: .plain)
        let refreshControl = RecordingRefreshControl()
        tableView.refreshControl = refreshControl
        coordinator.attach(to: tableView)
        coordinator.update(configuration: configuration, in: tableView)

        _ = coordinator.perform(
            NSSelectorFromString("refreshRequested:"),
            with: refreshControl
        )
        await gate.waitUntilStarted()
        await gate.release()
        await actionReturned.wait()
        for _ in 0..<10 {
            await Task.yield()
        }

        coordinator.update(
            configuration: makeConfiguration(
                refreshCompletionGeneration: 1,
                refresh: {}
            ),
            in: tableView
        )
        await scheduler.waitUntilScheduled()
        #expect(refreshControl.endCount == 0)

        coordinator.update(
            configuration: makeConfiguration(
                refreshCompletionGeneration: 1,
                refresh: nil
            ),
            in: tableView
        )
        #expect(refreshControl.endCount == 1)
        #expect(tableView.refreshControl == nil)

        scheduler.runNext()
        #expect(refreshControl.endCount == 1)
        #expect(animator.animationCount == 0)
    }

    private func makeConfiguration(
        refreshCompletionGeneration: UInt64 = 0,
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
            refreshDidComplete: {}
        )
    }
}

@MainActor
private final class ManualRefreshCollapseScheduler {
    private var pending: WorkspaceListTableCoordinator.RefreshCollapseAction?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var scheduleCount = 0

    func schedule(
        _ action: @escaping WorkspaceListTableCoordinator.RefreshCollapseAction
    ) {
        precondition(pending == nil)
        scheduleCount += 1
        pending = action
        waiter?.resume()
        waiter = nil
    }

    func waitUntilScheduled() async {
        guard pending == nil else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func runNext() {
        precondition(pending != nil)
        let action = pending
        pending = nil
        action?()
    }
}

@MainActor
private final class ManualRefreshCollapseAnimator {
    private var completion: WorkspaceListTableCoordinator.RefreshCollapseAction?
    private(set) var animationCount = 0

    func animate(
        _ refreshControl: UIRefreshControl,
        _ tableView: WorkspaceListUITableView,
        completion: @escaping WorkspaceListTableCoordinator.RefreshCollapseAction
    ) {
        precondition(self.completion == nil)
        animationCount += 1
        refreshControl.endRefreshing()
        self.completion = completion
    }

    func completeNext() {
        precondition(completion != nil)
        let completion = completion
        self.completion = nil
        completion?()
    }
}

@MainActor
private final class RecordingRefreshControl: UIRefreshControl {
    private(set) var endCount = 0

    override func endRefreshing() {
        endCount += 1
        super.endRefreshing()
    }
}

private actor RefreshActionGate {
    private var isReleased = false
    private var didStart = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor AsyncSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
#endif
