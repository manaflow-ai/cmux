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
        let refreshDidComplete = MainActorSignal()
        let configuration = makeConfiguration(
            refreshDidComplete: refreshDidComplete.signal
        ) {
            await gate.waitForRelease()
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
        await refreshDidComplete.wait()

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
        await refreshControl.waitUntilEndCount(1)
        #expect(refreshControl.endCount == 1)
        #expect(animator.animationCount == 1)

        _ = coordinator.perform(
            NSSelectorFromString("refreshRequested:"),
            with: refreshControl
        )
        await refreshControl.waitUntilEndCount(2)
        #expect(
            scheduler.scheduleCount == 1,
            "A refresh event during collapse must end without starting another refresh."
        )
        animator.completeNext()
    }

    @Test("ignores a queued collapse after refresh is removed")
    func ignoresQueuedCollapseAfterRefreshIsRemoved() async {
        let gate = RefreshActionGate()
        let refreshDidComplete = MainActorSignal()
        let configuration = makeConfiguration(
            refreshDidComplete: refreshDidComplete.signal
        ) {
            await gate.waitForRelease()
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
        await refreshDidComplete.wait()

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
        await refreshControl.waitUntilEndCount(1)
        #expect(refreshControl.endCount == 1)
        #expect(tableView.refreshControl == nil)

        scheduler.runNext()
        #expect(refreshControl.endCount == 1)
        #expect(animator.animationCount == 0)
    }

    @Test("cancels a queued collapse when the refresh control is replaced")
    func cancelsQueuedCollapseWhenRefreshControlIsReplaced() async {
        let firstGate = RefreshActionGate()
        let firstRefreshDidComplete = MainActorSignal()
        let configuration = makeConfiguration(
            refreshDidComplete: firstRefreshDidComplete.signal
        ) {
            await firstGate.waitForRelease()
        }
        let scheduler = ManualRefreshCollapseScheduler()
        let animator = ManualRefreshCollapseAnimator()
        let coordinator = WorkspaceListTableCoordinator(
            configuration: configuration,
            scheduleRefreshCollapse: scheduler.schedule,
            animateRefreshCollapse: animator.animate
        )
        let tableView = WorkspaceListUITableView(frame: .zero, style: .plain)
        let firstRefreshControl = RecordingRefreshControl()
        tableView.refreshControl = firstRefreshControl
        coordinator.attach(to: tableView)
        coordinator.update(configuration: configuration, in: tableView)

        _ = coordinator.perform(
            NSSelectorFromString("refreshRequested:"),
            with: firstRefreshControl
        )
        await firstGate.waitUntilStarted()
        await firstGate.release()
        await firstRefreshDidComplete.wait()

        coordinator.update(
            configuration: makeConfiguration(
                refreshCompletionGeneration: 1,
                refresh: {}
            ),
            in: tableView
        )
        await scheduler.waitUntilScheduled()

        let replacementRefreshControl = RecordingRefreshControl()
        tableView.refreshControl = replacementRefreshControl
        scheduler.runNext()
        await firstRefreshControl.waitUntilEndCount(1)
        #expect(animator.animationCount == 0)

        let secondRefreshDidComplete = MainActorSignal()
        let secondConfiguration = makeConfiguration(
            refreshCompletionGeneration: 1,
            refreshDidComplete: secondRefreshDidComplete.signal,
            refresh: {}
        )
        coordinator.update(configuration: secondConfiguration, in: tableView)
        _ = coordinator.perform(
            NSSelectorFromString("refreshRequested:"),
            with: replacementRefreshControl
        )
        await secondRefreshDidComplete.wait()

        coordinator.update(
            configuration: makeConfiguration(
                refreshCompletionGeneration: 2,
                refresh: {}
            ),
            in: tableView
        )
        await scheduler.waitUntilScheduled()
        #expect(scheduler.scheduleCount == 2)
        scheduler.runNext()
        await replacementRefreshControl.waitUntilEndCount(1)
        #expect(animator.animationCount == 1)
        animator.completeNext()
    }

    @Test("a stale cancelled task cannot release replacement task ownership")
    func staleCancelledTaskCannotReleaseReplacementTaskOwnership() async {
        let firstGate = RefreshActionGate()
        let firstCancellationObserved = AsyncBoolSignal()
        let firstTaskDidFinish = MainActorSignal()
        let firstConfiguration = makeConfiguration {
            await firstGate.waitForRelease()
            await firstCancellationObserved.signal(Task.isCancelled)
        }
        let scheduler = ManualRefreshCollapseScheduler()
        let animator = ManualRefreshCollapseAnimator()
        let coordinator = WorkspaceListTableCoordinator(
            configuration: firstConfiguration,
            scheduleRefreshCollapse: scheduler.schedule,
            animateRefreshCollapse: animator.animate,
            refreshTaskDidFinish: firstTaskDidFinish.signal
        )
        let tableView = WorkspaceListUITableView(frame: .zero, style: .plain)
        let firstRefreshControl = RecordingRefreshControl()
        tableView.refreshControl = firstRefreshControl
        coordinator.attach(to: tableView)
        coordinator.update(configuration: firstConfiguration, in: tableView)

        _ = coordinator.perform(
            NSSelectorFromString("refreshRequested:"),
            with: firstRefreshControl
        )
        await firstGate.waitUntilStarted()

        coordinator.update(
            configuration: makeConfiguration(refresh: nil),
            in: tableView
        )
        await firstRefreshControl.waitUntilEndCount(1)

        let secondGate = RefreshActionGate()
        let secondCancellationObserved = AsyncBoolSignal()
        let secondConfiguration = makeConfiguration {
            await secondGate.waitForRelease()
            await secondCancellationObserved.signal(Task.isCancelled)
        }
        coordinator.update(configuration: secondConfiguration, in: tableView)
        let secondRefreshControl = RecordingRefreshControl()
        tableView.refreshControl = secondRefreshControl
        _ = coordinator.perform(
            NSSelectorFromString("refreshRequested:"),
            with: secondRefreshControl
        )
        await secondGate.waitUntilStarted()

        await firstGate.release()
        let firstWasCancelled = await firstCancellationObserved.wait()
        #expect(firstWasCancelled)
        await firstTaskDidFinish.wait()
        #expect(firstRefreshControl.endCount == 1)

        coordinator.update(
            configuration: makeConfiguration(refresh: nil),
            in: tableView
        )
        await secondRefreshControl.waitUntilEndCount(1)
        await secondGate.release()
        let secondWasCancelled = await secondCancellationObserved.wait()
        #expect(
            secondWasCancelled,
            "The stale first task must not clear the replacement task handle."
        )
    }

    @Test("dismantling the table cancels its refresh task and ends its control")
    func dismantleCancelsRefreshTaskAndEndsControl() async {
        let gate = RefreshActionGate()
        let cancellationObserved = AsyncBoolSignal()
        let configuration = makeConfiguration {
            await gate.waitForRelease()
            await cancellationObserved.signal(Task.isCancelled)
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

        WorkspaceListTable.dismantleUIView(tableView, coordinator: coordinator)
        await refreshControl.waitUntilEndCount(1)
        #expect(tableView.refreshControl == nil)
        #expect(tableView.delegate == nil)
        #expect(tableView.dragDelegate == nil)
        #expect(tableView.dropDelegate == nil)

        await gate.release()
        let wasCancelled = await cancellationObserved.wait()
        #expect(wasCancelled)
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
    private var endWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    override func endRefreshing() {
        endCount += 1
        super.endRefreshing()
        var remaining: [(
            count: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        for waiter in endWaiters {
            if endCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        endWaiters = remaining
    }

    func waitUntilEndCount(_ count: Int) async {
        guard endCount < count else { return }
        await withCheckedContinuation { continuation in
            endWaiters.append((count, continuation))
        }
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

private actor AsyncBoolSignal {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func signal(_ value: Bool) {
        precondition(result == nil)
        result = value
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
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
