#if os(iOS)
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

@Suite("Workspace list refresh coordinator")
@MainActor
struct WorkspaceListRefreshCoordinatorTests {
    @Test("keeps refresh geometry inside a neutral representable root")
    func keepsRefreshGeometryInsideNeutralRoot() {
        let host = makeContainer()

        #expect(host.containerView.tableView.superview === host.containerView)
        #expect(host.containerView.tableView.frame == host.containerView.bounds)
    }

    @Test("keeps custom refresh geometry held until a post-refresh snapshot arrives")
    func keepsCustomRefreshHeldUntilPostRefreshSnapshot() async {
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
        let host = makeContainer()
        coordinator.attach(to: host.containerView)
        coordinator.update(configuration: configuration, in: host.tableView)
        let baselineTopInset = host.tableView.contentInset.top

        #expect(host.tableView.refreshControl == nil && refreshHeader(in: host.tableView) != nil)
        #expect(coordinator.beginRefresh())
        await gate.waitUntilStarted()
        coordinator.scrollViewWillBeginDragging(host.tableView)
        #expect(
            host.tableView.contentInset.top
                == baselineTopInset + WorkspaceListRefreshGeometry.holdHeight
        )

        await gate.release()
        await refreshDidComplete.wait()

        #expect(
            host.tableView.contentInset.top
                == baselineTopInset + WorkspaceListRefreshGeometry.holdHeight,
            "Refresh completion must wait for the authoritative post-refresh snapshot."
        )

        let completedConfiguration = makeConfiguration(
            refreshCompletionGeneration: 1,
            refresh: {}
        )
        coordinator.update(configuration: completedConfiguration, in: host.tableView)
        await scheduler.waitUntilScheduled()
        #expect(scheduler.scheduleCount == 1)
        #expect(
            host.tableView.contentInset.top
                == baselineTopInset + WorkspaceListRefreshGeometry.holdHeight,
            "The snapshot completion must only schedule the visible collapse."
        )

        scheduler.runNext()
        #expect(animator.animationCount == 1)
        #expect(!coordinator.beginRefresh())
        animator.completeNext()
        #expect(host.tableView.contentInset.top == baselineTopInset)
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
        let host = makeContainer()
        let baselineInset = host.tableView.contentInset
        let baselineIndicatorInsets = host.tableView.verticalScrollIndicatorInsets
        let baselineAlwaysBounces = host.tableView.alwaysBounceVertical
        let baselineBounces = host.tableView.bounces
        coordinator.attach(to: host.containerView)
        coordinator.update(configuration: configuration, in: host.tableView)

        #expect(coordinator.beginRefresh())
        await gate.waitUntilStarted()
        coordinator.scrollViewWillBeginDragging(host.tableView)
        await gate.release()
        await refreshDidComplete.wait()

        coordinator.update(
            configuration: makeConfiguration(
                refreshCompletionGeneration: 1,
                refresh: {}
            ),
            in: host.tableView
        )
        await scheduler.waitUntilScheduled()

        coordinator.update(
            configuration: makeConfiguration(
                refreshCompletionGeneration: 1,
                refresh: nil
            ),
            in: host.tableView
        )
        #expect(host.tableView.contentInset == baselineInset)
        #expect(host.tableView.verticalScrollIndicatorInsets == baselineIndicatorInsets)
        #expect(host.tableView.alwaysBounceVertical == baselineAlwaysBounces)
        #expect(host.tableView.bounces == baselineBounces)
        #expect(refreshHeader(in: host.tableView) == nil)

        scheduler.runNext()
        #expect(animator.animationCount == 0)
    }

    @Test("triggers only at the custom pull threshold")
    func triggersOnlyAtCustomPullThreshold() async {
        let gate = RefreshActionGate()
        let configuration = makeConfiguration {
            await gate.waitForRelease()
        }
        let host = makeContainer()
        let coordinator = WorkspaceListTableCoordinator(configuration: configuration)
        coordinator.attach(to: host.containerView)
        coordinator.update(configuration: configuration, in: host.tableView)
        let baselineTopInset = host.tableView.contentInset.top
        let restingOffsetY = -host.tableView.adjustedContentInset.top

        host.tableView.contentOffset.y = restingOffsetY
            - WorkspaceListRefreshGeometry.triggerDistance + 1
        _ = endDrag(coordinator: coordinator, tableView: host.tableView)
        #expect(coordinator.refreshTask == nil)

        host.tableView.contentOffset.y = restingOffsetY
            - WorkspaceListRefreshGeometry.triggerDistance
        let releasedOffset = host.tableView.contentOffset
        var releaseTarget = releasedOffset
        withUnsafeMutablePointer(to: &releaseTarget) { pointer in
            coordinator.scrollViewWillEndDragging(
                host.tableView,
                withVelocity: .zero,
                targetContentOffset: pointer
            )
        }
        await gate.waitUntilStarted()
        #expect(releaseTarget == releasedOffset)
        #expect(
            host.tableView.contentInset.top
                == baselineTopInset + WorkspaceListRefreshGeometry.triggerDistance
        )
        #expect(!host.tableView.bounces)
        #expect(coordinator.refreshVisualAnimator == nil)
        coordinator.scrollViewDidEndDragging(
            host.tableView,
            willDecelerate: false
        )
        #expect(coordinator.refreshVisualAnimator != nil)
        #expect(coordinator.refreshTask != nil)
        #expect(!coordinator.beginRefresh())

        coordinator.update(configuration: makeConfiguration(refresh: nil), in: host.tableView)
        await gate.release()
    }

    @Test("a stale cancelled task cannot release replacement task ownership")
    func staleCancelledTaskCannotReleaseReplacementTaskOwnership() async throws {
        let firstGate = RefreshActionGate()
        let firstCancellationObserved = AsyncBoolSignal()
        let firstConfiguration = makeConfiguration {
            await firstGate.waitForRelease()
            await firstCancellationObserved.signal(Task.isCancelled)
        }
        let scheduler = ManualRefreshCollapseScheduler()
        let animator = ManualRefreshCollapseAnimator()
        let coordinator = WorkspaceListTableCoordinator(
            configuration: firstConfiguration,
            scheduleRefreshCollapse: scheduler.schedule,
            animateRefreshCollapse: animator.animate
        )
        let host = makeContainer()
        coordinator.attach(to: host.containerView)
        coordinator.update(configuration: firstConfiguration, in: host.tableView)

        #expect(coordinator.beginRefresh())
        await firstGate.waitUntilStarted()
        let firstTask = try #require(coordinator.refreshTask)

        coordinator.update(
            configuration: makeConfiguration(refresh: nil),
            in: host.tableView
        )

        let secondGate = RefreshActionGate()
        let secondCancellationObserved = AsyncBoolSignal()
        let secondConfiguration = makeConfiguration {
            await secondGate.waitForRelease()
            await secondCancellationObserved.signal(Task.isCancelled)
        }
        coordinator.update(configuration: secondConfiguration, in: host.tableView)
        #expect(coordinator.beginRefresh())
        await secondGate.waitUntilStarted()
        let secondTask = try #require(coordinator.refreshTask)

        await firstGate.release()
        await firstTask.value
        let firstWasCancelled = await firstCancellationObserved.wait()
        #expect(firstWasCancelled)
        #expect(coordinator.refreshTask != nil)

        coordinator.update(
            configuration: makeConfiguration(refresh: nil),
            in: host.tableView
        )
        await secondGate.release()
        await secondTask.value
        let secondWasCancelled = await secondCancellationObserved.wait()
        #expect(
            secondWasCancelled,
            "The stale first task must not clear the replacement task handle."
        )
    }

    @Test("dismantling restores exact refresh geometry and cancels its task")
    func dismantleRestoresRefreshGeometryAndCancelsTask() async {
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
        let host = makeContainer()
        host.tableView.contentInset = UIEdgeInsets(top: 8, left: 1, bottom: 2, right: 3)
        host.tableView.verticalScrollIndicatorInsets = UIEdgeInsets(
            top: 9,
            left: 4,
            bottom: 5,
            right: 6
        )
        host.tableView.alwaysBounceVertical = false
        let baselineInset = host.tableView.contentInset
        let baselineIndicatorInsets = host.tableView.verticalScrollIndicatorInsets
        let baselineBounces = host.tableView.bounces
        coordinator.attach(to: host.containerView)
        coordinator.update(configuration: configuration, in: host.tableView)

        #expect(coordinator.beginRefresh())
        await gate.waitUntilStarted()
        coordinator.scrollViewWillBeginDragging(host.tableView)

        WorkspaceListTable.dismantleUIView(host.containerView, coordinator: coordinator)
        #expect(host.tableView.contentInset == baselineInset)
        #expect(host.tableView.verticalScrollIndicatorInsets == baselineIndicatorInsets)
        #expect(!host.tableView.alwaysBounceVertical)
        #expect(host.tableView.bounces == baselineBounces)
        #expect(refreshHeader(in: host.tableView) == nil)
        #expect(host.tableView.delegate == nil)
        #expect(host.tableView.dragDelegate == nil)
        #expect(host.tableView.dropDelegate == nil)

        await gate.release()
        let wasCancelled = await cancellationObserved.wait()
        #expect(wasCancelled)
    }

    private func makeContainer() -> WorkspaceListTableTestHost {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let viewController = UIViewController()
        window.rootViewController = viewController
        let containerView = WorkspaceListTableContainerView()
        containerView.frame = viewController.view.bounds
        containerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        viewController.view.addSubview(containerView)
        window.isHidden = false
        viewController.view.layoutIfNeeded()
        containerView.layoutIfNeeded()
        return WorkspaceListTableTestHost(
            window: window,
            containerView: containerView
        )
    }

    private func refreshHeader(
        in tableView: WorkspaceListUITableView
    ) -> WorkspaceListRefreshHeaderView? {
        tableView.subviews.first { view in
            view.accessibilityIdentifier == "MobileWorkspaceRefreshHeader"
        } as? WorkspaceListRefreshHeaderView
    }

    private func endDrag(
        coordinator: WorkspaceListTableCoordinator,
        tableView: WorkspaceListUITableView
    ) -> CGPoint {
        var targetContentOffset = tableView.contentOffset
        withUnsafeMutablePointer(to: &targetContentOffset) { pointer in
            coordinator.scrollViewWillEndDragging(
                tableView,
                withVelocity: .zero,
                targetContentOffset: pointer
            )
        }
        coordinator.scrollViewDidEndDragging(tableView, willDecelerate: false)
        return targetContentOffset
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
private struct WorkspaceListTableTestHost {
    let window: UIWindow
    let containerView: WorkspaceListTableContainerView

    var tableView: WorkspaceListUITableView {
        containerView.tableView
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
    private weak var tableView: WorkspaceListUITableView?
    private(set) var animationCount = 0

    func animate(
        _ tableView: WorkspaceListUITableView,
        completion: @escaping WorkspaceListTableCoordinator.RefreshCollapseAction
    ) {
        precondition(self.completion == nil)
        animationCount += 1
        self.tableView = tableView
        self.completion = completion
    }

    func completeNext() {
        precondition(completion != nil)
        if let tableView {
            tableView.contentInset.top -= WorkspaceListRefreshGeometry.holdHeight
            tableView.verticalScrollIndicatorInsets.top -=
                WorkspaceListRefreshGeometry.holdHeight
            tableView.contentOffset.y = max(
                tableView.contentOffset.y,
                -tableView.adjustedContentInset.top
            )
        }
        tableView = nil
        let completion = completion
        self.completion = nil
        completion?()
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
