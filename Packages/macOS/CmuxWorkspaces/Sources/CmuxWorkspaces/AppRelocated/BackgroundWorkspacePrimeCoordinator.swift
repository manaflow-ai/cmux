import Foundation
import CmuxTerminal

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

        func addObserver(_ observer: NSObjectProtocol) {
            addCleanup { NotificationCenter.default.removeObserver(observer) }
        }

        func addTask(_ task: Task<Void, Never>) {
            addCleanup { task.cancel() }
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

    deinit {
        // Explicit for the required_deinit lint; per-prime resources live on Waiter.
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

                installReadinessObservers(
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

    private func installReadinessObservers(
        waiter: Waiter,
        workspaceId: UUID,
        tabManager: TabManager
    ) {
        let readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { [weak self, weak waiter, weak tabManager] notification in
            guard let readyWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                  readyWorkspaceId == workspaceId,
                  let self,
                  let waiter,
                  let tabManager else { return }
            Task { @MainActor in
                self.evaluate(waiter: waiter, workspaceId: workspaceId, tabManager: tabManager)
            }
        }
        waiter.addObserver(readyObserver)

        let hostedViewObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { [weak self, weak waiter, weak tabManager] notification in
            guard let readyWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                  readyWorkspaceId == workspaceId,
                  let self,
                  let waiter,
                  let tabManager else { return }
            Task { @MainActor in
                self.evaluate(waiter: waiter, workspaceId: workspaceId, tabManager: tabManager)
            }
        }
        waiter.addObserver(hostedViewObserver)

        // Observation replaces the retired `$pendingBackgroundWorkspaceLoadIds`
        // Combine bridge. `withObservationTracking` fires only on a genuine
        // change (never an initial emit), matching the previous `.dropFirst()`,
        // and re-arms itself until the waiter resolves so subsequent drains are
        // still observed. The change handler reads the post-change set on the
        // MainActor, mirroring the sink body.
        observePendingBackgroundWorkspaceLoadDrain(
            waiter: waiter,
            workspaceId: workspaceId,
            tabManager: tabManager
        )

        // Observation replaces the retired `tabsPublisher` Combine bridge.
        // `withObservationTracking` fires only on a genuine change (never an
        // initial emit), matching the previous `.dropFirst()`, and re-arms
        // itself until the waiter resolves so a later removal is still observed.
        observeWorkspaceRemovalFromTabs(
            waiter: waiter,
            workspaceId: workspaceId,
            tabManager: tabManager
        )
    }

    /// Re-arming Observation watch on the `@Observable` ``WorkspacesModel``
    /// `tabs` list, replacing the retired `tabsPublisher` Combine bridge fed by
    /// the legacy `@Published tabs`. `onChange` fires once per genuine change
    /// (at `willSet` time), so the handler hops to the MainActor to read the
    /// post-change list, fires `evaluate` when this workspace has been removed,
    /// then re-arms unless the waiter has resolved. The re-arm task is
    /// registered with the waiter so it is cancelled on completion/teardown,
    /// mirroring the old cancellable's lifetime (and the sibling
    /// ``observePendingBackgroundWorkspaceLoadDrain(waiter:workspaceId:tabManager:)``).
    private func observeWorkspaceRemovalFromTabs(
        waiter: Waiter,
        workspaceId: UUID,
        tabManager: TabManager
    ) {
        guard !waiter.isResolved else { return }
        let model = tabManager.workspaces
        withObservationTracking {
            _ = model.tabs
        } onChange: { [weak self, weak waiter, weak tabManager] in
            let rearm = Task { @MainActor [weak self, weak waiter, weak tabManager] in
                guard let self, let waiter, let tabManager, !waiter.isResolved else { return }
                if !tabManager.tabs.contains(where: { $0.id == workspaceId }) {
                    self.evaluate(waiter: waiter, workspaceId: workspaceId, tabManager: tabManager)
                }
                self.observeWorkspaceRemovalFromTabs(
                    waiter: waiter,
                    workspaceId: workspaceId,
                    tabManager: tabManager
                )
            }
            waiter?.addTask(rearm)
        }
    }

    /// Re-arming Observation watch on the `@Observable`
    /// ``BackgroundWorkspaceLoadModel`` pending-load set, replacing the retired
    /// `$pendingBackgroundWorkspaceLoadIds` Combine bridge. `onChange` fires
    /// once per genuine change (before the change commits), so the handler hops
    /// to the MainActor to read the post-change set, fires `evaluate` when this
    /// workspace has drained out of the pending set, then re-arms unless the
    /// waiter has resolved. The re-arm task is registered with the waiter so it
    /// is cancelled on completion/teardown, mirroring the old cancellable's
    /// lifetime.
    private func observePendingBackgroundWorkspaceLoadDrain(
        waiter: Waiter,
        workspaceId: UUID,
        tabManager: TabManager
    ) {
        guard !waiter.isResolved else { return }
        let model = tabManager.backgroundWorkspaceLoad
        withObservationTracking {
            _ = model.pendingBackgroundWorkspaceLoadIds
        } onChange: { [weak self, weak waiter, weak tabManager] in
            let rearm = Task { @MainActor [weak self, weak waiter, weak tabManager] in
                guard let self, let waiter, let tabManager, !waiter.isResolved else { return }
                if !tabManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) {
                    self.evaluate(waiter: waiter, workspaceId: workspaceId, tabManager: tabManager)
                }
                self.observePendingBackgroundWorkspaceLoadDrain(
                    waiter: waiter,
                    workspaceId: workspaceId,
                    tabManager: tabManager
                )
            }
            waiter?.addTask(rearm)
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
