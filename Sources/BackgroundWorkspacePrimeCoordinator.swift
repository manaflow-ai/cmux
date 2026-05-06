import Foundation

@MainActor
final class BackgroundWorkspacePrimeCoordinator {
    private nonisolated enum PrimeState {
        case pending
        case completed(reason: String)
    }

    private nonisolated enum Policy {
        static let timeoutSeconds: TimeInterval = 2.0
        static let maxTimeoutRetries = 3
    }

    private nonisolated final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Never>?
        private var cleanupActions: [() -> Void] = []
        private var resolvedReason: String?

        var isResolved: Bool {
            lock.lock()
            defer { lock.unlock() }
            return resolvedReason != nil
        }

        deinit {
            finish(reason: "cancelled")
        }

        func start(continuation: CheckedContinuation<String, Never>) {
            let reason: String?
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

        func addTimeoutWorkItem(_ workItem: DispatchWorkItem) {
            addCleanup { workItem.cancel() }
        }

        func finish(reason: String) {
            let drained: (CheckedContinuation<String, Never>?, [() -> Void])?
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

    private var timeoutCounts: [UUID: Int] = [:]

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
                guard reason == "timeout" else {
                    timeoutCounts[workspaceId] = nil
                    continue
                }

                let timeoutCount = (timeoutCounts[workspaceId] ?? 0) + 1
                timeoutCounts[workspaceId] = timeoutCount
                if timeoutCount >= Policy.maxTimeoutRetries {
                    tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
                    timeoutCounts[workspaceId] = nil
                }
            }
        }
    }

    private func primeBackgroundWorkspaceIfNeeded(workspaceId: UUID, tabManager: TabManager) async -> String {
        guard tabManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else {
            return "already_cleared"
        }

#if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        cmuxDebugLog("workspace.backgroundPrime.start workspace=\(workspaceId.uuidString.prefix(5))")
#endif

        let completionReason: String
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
            "reason=\(completionReason) ms=\(String(format: "%.2f", elapsedMs))"
        )
#endif
        return completionReason
    }

    private func stepBackgroundWorkspacePrime(workspaceId: UUID, tabManager: TabManager) -> PrimeState {
        guard tabManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else {
            return .completed(reason: "already_cleared")
        }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
            timeoutCounts[workspaceId] = nil
            return .completed(reason: "workspace_removed")
        }

        workspace.requestBackgroundPrimeTerminalSurfaceStartIfNeeded()
        guard workspace.hasLoadedBackgroundPrimeTerminalSurface() else {
            return .pending
        }

        tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
        timeoutCounts[workspaceId] = nil
        return .completed(reason: "surface_ready")
    }

    private func waitForBackgroundWorkspacePrimeCompletion(
        workspaceId: UUID,
        timeoutSeconds: TimeInterval,
        tabManager: TabManager
    ) async -> String {
        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                waiter.start(continuation: continuation)
                guard !waiter.isResolved else { return }

                installReadinessObservers(
                    waiter: waiter,
                    workspaceId: workspaceId,
                    tabManager: tabManager
                )

                let timeoutWorkItem = DispatchWorkItem { [weak self, weak waiter, weak tabManager] in
                    guard let self, let waiter, let tabManager else { return }
                    Task { @MainActor in
                        if case .completed(let reason) = self.stepBackgroundWorkspacePrime(
                            workspaceId: workspaceId,
                            tabManager: tabManager
                        ) {
                            waiter.finish(reason: reason)
                        } else {
                            waiter.finish(reason: "timeout")
                        }
                    }
                }
                waiter.addTimeoutWorkItem(timeoutWorkItem)
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + timeoutSeconds,
                    execute: timeoutWorkItem
                )

                evaluate(waiter: waiter, workspaceId: workspaceId, tabManager: tabManager)
            }
        } onCancel: {
            waiter.finish(reason: "cancelled")
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
