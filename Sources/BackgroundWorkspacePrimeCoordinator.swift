import Foundation
import Combine

@MainActor
final class BackgroundWorkspacePrimeCoordinator {
    private nonisolated enum PrimeCompletionReason: String {
        case alreadyCleared = "already_cleared"
        case cancelled
        case noSurfaceWork = "no_surface_work"
        case surfaceReady = "surface_ready"
        case timeout
        case workspaceRemoved = "workspace_removed"
    }

    private nonisolated enum PrimeState {
        case pending
        case completed(reason: PrimeCompletionReason)
    }

    private nonisolated enum Policy {
        static let timeoutSeconds: TimeInterval = 2.0
    }

    private nonisolated final class Waiter: @unchecked Sendable {
        // Cancellation handlers cannot await an actor hop; this lock keeps continuation
        // and cleanup state synchronous across task cancellation and readiness callbacks.
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PrimeCompletionReason, Never>?
        private var cleanupActions: [() -> Void] = []
        private var resolvedReason: PrimeCompletionReason?

        var isResolved: Bool {
            lock.lock()
            defer { lock.unlock() }
            return resolvedReason != nil
        }

        deinit {
            finish(reason: .cancelled)
        }

        func start(continuation: CheckedContinuation<PrimeCompletionReason, Never>) {
            let reason: PrimeCompletionReason?
            lock.lock()
            reason = resolvedReason
            if reason == nil {
                self.continuation = continuation
            }
            lock.unlock()
            if let reason {
                continuation.resume(returning: reason)
            }
        }

        func addTask(_ task: Task<Void, Never>) {
            addCleanup { task.cancel() }
        }

        func addCleanupAction(_ action: @escaping () -> Void) {
            addCleanup(action)
        }

        func finish(reason: PrimeCompletionReason) {
            let drained: (CheckedContinuation<PrimeCompletionReason, Never>?, [() -> Void])?
            lock.lock()
            if resolvedReason == nil {
                resolvedReason = reason
                drained = (continuation, cleanupActions)
                continuation = nil
                cleanupActions.removeAll()
            } else {
                drained = nil
            }
            lock.unlock()

            guard let (continuation, cleanupActions) = drained else { return }
            cleanupActions.forEach { $0() }
            continuation?.resume(returning: reason)
        }

        private func addCleanup(_ action: @escaping () -> Void) {
            lock.lock()
            guard resolvedReason == nil else {
                lock.unlock()
                action()
                return
            }
            cleanupActions.append(action)
            lock.unlock()
        }
    }

    private struct RegisteredWaiter {
        let id: UUID
        weak var waiter: Waiter?
    }

    private weak var observedTabManager: TabManager?
    private var readinessWaitersByWorkspaceId: [UUID: [RegisteredWaiter]] = [:]
    private var readinessCancellables: Set<AnyCancellable> = []
    private var readinessObservers: [NSObjectProtocol] = []

    deinit {
        readinessCancellables.forEach { $0.cancel() }
        readinessObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func taskKey(for tabManager: TabManager) -> [String] {
        tabManager.pendingBackgroundWorkspaceLoadIds
            .map(\.uuidString)
            .sorted()
    }

    func primePendingBackgroundWorkspaces(tabManager: TabManager) async {
        while !Task.isCancelled {
            let workspaceIds = tabManager.pendingBackgroundWorkspaceLoadIds.sorted { $0.uuidString < $1.uuidString }
            guard !workspaceIds.isEmpty else { return }
            for workspaceId in workspaceIds {
                guard !Task.isCancelled else { return }
                let reason = await primeBackgroundWorkspaceIfNeeded(workspaceId: workspaceId, tabManager: tabManager)
                guard !Task.isCancelled else { return }

                switch reason {
                case .timeout:
                    // Keep the hidden mount retained; pending background initial commands
                    // must stay eligible to start until the surface is actually ready.
                    continue
                case .cancelled:
                    continue
                case .alreadyCleared, .noSurfaceWork, .surfaceReady, .workspaceRemoved:
                    continue
                }
            }
        }
    }

    private func primeBackgroundWorkspaceIfNeeded(
        workspaceId: UUID,
        tabManager: TabManager
    ) async -> PrimeCompletionReason {
        guard tabManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else {
            tabManager.releaseBackgroundWorkspaceMount(for: workspaceId)
            return .alreadyCleared
        }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .workspaceRemoved
        }
        guard workspace.hasBackgroundPrimeTerminalSurfaceStartWork() else {
            tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .noSurfaceWork
        }
        guard !workspace.hasLoadedBackgroundPrimeTerminalSurface() else {
            tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .surfaceReady
        }

        tabManager.retainBackgroundWorkspaceMount(for: workspaceId)

#if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        cmuxDebugLog("workspace.backgroundPrime.start workspace=\(workspaceId.uuidString.prefix(5))")
#endif

        let completionReason: PrimeCompletionReason
        switch stepBackgroundWorkspacePrime(workspaceId: workspaceId, tabManager: tabManager) {
        case .completed(let reason):
            completionReason = reason
        case .pending:
            completionReason = await waitForBackgroundWorkspacePrimeCompletion(
                workspaceId: workspaceId,
                timeoutSeconds: Policy.timeoutSeconds,
                tabManager: tabManager
            )
        }

#if DEBUG
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        cmuxDebugLog(
            "workspace.backgroundPrime.finish workspace=\(workspaceId.uuidString.prefix(5)) " +
            "reason=\(completionReason.rawValue) ms=\(String(format: "%.2f", elapsedMs))"
        )
#endif
        return completionReason
    }

    private func stepBackgroundWorkspacePrime(workspaceId: UUID, tabManager: TabManager) -> PrimeState {
        guard tabManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else {
            tabManager.releaseBackgroundWorkspaceMount(for: workspaceId)
            return .completed(reason: .alreadyCleared)
        }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .completed(reason: .workspaceRemoved)
        }
        guard workspace.hasBackgroundPrimeTerminalSurfaceStartWork() else {
            tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .completed(reason: .noSurfaceWork)
        }
        guard !workspace.hasLoadedBackgroundPrimeTerminalSurface() else {
            tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .completed(reason: .surfaceReady)
        }

        workspace.requestBackgroundPrimeTerminalSurfaceStartIfNeeded()
        guard workspace.hasLoadedBackgroundPrimeTerminalSurface() else {
            return .pending
        }

        tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
        return .completed(reason: .surfaceReady)
    }

    private func waitForBackgroundWorkspacePrimeCompletion(
        workspaceId: UUID,
        timeoutSeconds: TimeInterval,
        tabManager: TabManager
    ) async -> PrimeCompletionReason {
        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PrimeCompletionReason, Never>) in
                waiter.start(continuation: continuation)
                guard !waiter.isResolved else { return }

                registerReadinessWaiter(
                    waiter: waiter,
                    workspaceId: workspaceId,
                    tabManager: tabManager
                )

                let timeoutNanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
                let timeoutTask = Task { @MainActor [weak self, weak waiter, weak tabManager] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, let self, let waiter, let tabManager else { return }
                    if case .completed(let reason) = self.stepBackgroundWorkspacePrime(
                        workspaceId: workspaceId,
                        tabManager: tabManager
                    ) {
                        waiter.finish(reason: reason)
                    } else {
                        waiter.finish(reason: .timeout)
                    }
                }
                waiter.addTask(timeoutTask)

                evaluate(waiter: waiter, workspaceId: workspaceId, tabManager: tabManager)
            }
        } onCancel: {
            waiter.finish(reason: .cancelled)
        }
    }

    private func registerReadinessWaiter(
        waiter: Waiter,
        workspaceId: UUID,
        tabManager: TabManager
    ) {
        ensureSharedReadinessObservers(tabManager: tabManager)
        let registrationId = UUID()
        readinessWaitersByWorkspaceId[workspaceId, default: []].append(
            RegisteredWaiter(id: registrationId, waiter: waiter)
        )
        waiter.addCleanupAction { [weak self] in
            Task { @MainActor in
                self?.unregisterReadinessWaiter(registrationId: registrationId, workspaceId: workspaceId)
            }
        }
    }

    private func ensureSharedReadinessObservers(tabManager: TabManager) {
        if let observedTabManager, observedTabManager === tabManager {
            return
        }

        readinessCancellables.forEach { $0.cancel() }
        readinessCancellables.removeAll(keepingCapacity: false)
        readinessObservers.forEach { NotificationCenter.default.removeObserver($0) }
        readinessObservers.removeAll(keepingCapacity: false)
        cancelRegisteredReadinessWaiters()
        observedTabManager = tabManager

        let readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { [weak self, weak tabManager] notification in
            guard let readyWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                  let self,
                  let tabManager else { return }
            Task { @MainActor in
                self.evaluateRegisteredWaiters(for: readyWorkspaceId, tabManager: tabManager)
            }
        }
        readinessObservers.append(readyObserver)

        let hostedViewObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { [weak self, weak tabManager] notification in
            guard let readyWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                  let self,
                  let tabManager else { return }
            Task { @MainActor in
                self.evaluateRegisteredWaiters(for: readyWorkspaceId, tabManager: tabManager)
            }
        }
        readinessObservers.append(hostedViewObserver)

        let pendingObserver = tabManager.$pendingBackgroundWorkspaceLoadIds
            .dropFirst()
            .sink { [weak self, weak tabManager] pendingIds in
                guard let self, let tabManager else { return }
                Task { @MainActor in
                    self.handlePendingWorkspaceIdsChange(pendingIds, tabManager: tabManager)
                }
            }
        readinessCancellables.insert(pendingObserver)

        let tabsObserver = tabManager.$tabs
            .dropFirst()
            .sink { [weak self, weak tabManager] tabs in
                let tabIds = Set(tabs.map(\.id))
                guard let self, let tabManager else { return }
                Task { @MainActor in
                    self.handleTabIdsChange(tabIds, tabManager: tabManager)
                }
            }
        readinessCancellables.insert(tabsObserver)
    }

    private func cancelRegisteredReadinessWaiters() {
        let waiters = readinessWaitersByWorkspaceId.values.flatMap { registrations in
            registrations.compactMap(\.waiter)
        }
        readinessWaitersByWorkspaceId.removeAll(keepingCapacity: false)
        waiters.forEach { $0.finish(reason: .cancelled) }
    }

    private func unregisterReadinessWaiter(registrationId: UUID, workspaceId: UUID) {
        guard var waiters = readinessWaitersByWorkspaceId[workspaceId] else { return }
        waiters.removeAll { $0.id == registrationId || $0.waiter == nil || $0.waiter?.isResolved == true }
        if waiters.isEmpty {
            readinessWaitersByWorkspaceId.removeValue(forKey: workspaceId)
        } else {
            readinessWaitersByWorkspaceId[workspaceId] = waiters
        }
    }

    private func handlePendingWorkspaceIdsChange(_ pendingIds: Set<UUID>, tabManager: TabManager) {
        let readyWorkspaceIds = readinessWaitersByWorkspaceId.keys.filter { !pendingIds.contains($0) }
        for workspaceId in readyWorkspaceIds {
            evaluateRegisteredWaiters(for: workspaceId, tabManager: tabManager)
        }
    }

    private func handleTabIdsChange(_ tabIds: Set<UUID>, tabManager: TabManager) {
        let removedWorkspaceIds = readinessWaitersByWorkspaceId.keys.filter { !tabIds.contains($0) }
        for workspaceId in removedWorkspaceIds {
            evaluateRegisteredWaiters(for: workspaceId, tabManager: tabManager)
        }
    }

    private func evaluateRegisteredWaiters(for workspaceId: UUID, tabManager: TabManager) {
        guard var waiters = readinessWaitersByWorkspaceId[workspaceId] else { return }
        waiters.removeAll { $0.waiter == nil || $0.waiter?.isResolved == true }
        for registration in waiters {
            guard let waiter = registration.waiter else { continue }
            evaluate(waiter: waiter, workspaceId: workspaceId, tabManager: tabManager)
        }
        waiters.removeAll { $0.waiter == nil || $0.waiter?.isResolved == true }
        if waiters.isEmpty {
            readinessWaitersByWorkspaceId.removeValue(forKey: workspaceId)
        } else {
            readinessWaitersByWorkspaceId[workspaceId] = waiters
        }
    }

    private func evaluate(waiter: Waiter, workspaceId: UUID, tabManager: TabManager) {
        switch stepBackgroundWorkspacePrime(workspaceId: workspaceId, tabManager: tabManager) {
        case .pending:
            break
        case .completed(let reason):
            waiter.finish(reason: reason)
        }
    }
}
