import Foundation
import Combine
import CmuxTerminal
import CmuxWorkspaces

enum BackgroundWorkspacePrimeWorkState: Sendable {
    case workspaceRemoved
    case noSurfaceWork
    case needsSurfaceStart
    case ready
}

@MainActor
protocol BackgroundWorkspacePrimeHosting: AnyObject, Sendable {
    var pendingBackgroundWorkspaceLoadIds: Set<UUID> { get }
    var backgroundWorkspacePrimePendingPublisher: AnyPublisher<Set<UUID>, Never> { get }
    var backgroundWorkspacePrimeWorkspaceIDsPublisher: AnyPublisher<Set<UUID>, Never> { get }

    func backgroundWorkspacePrimeWorkState(for workspaceID: UUID) -> BackgroundWorkspacePrimeWorkState
    func requestBackgroundWorkspacePrimeSurfaceStart(for workspaceID: UUID)
    func completeBackgroundWorkspaceLoad(for workspaceID: UUID)
}

@MainActor
final class BackgroundWorkspacePrimeCoordinator {
    typealias TimeoutSleep = @Sendable () async throws -> Void

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

    private let timeoutSleep: TimeoutSleep

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

        func addCancellable(_ cancellable: AnyCancellable) {
            addCleanup { cancellable.cancel() }
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

    init(timeoutSleep: @escaping TimeoutSleep = {
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }) {
        self.timeoutSleep = timeoutSleep
    }

    deinit {
        // Explicit for the required_deinit lint; per-prime resources live on Waiter.
    }

    func taskKey(for host: any BackgroundWorkspacePrimeHosting) -> [String] {
        host.pendingBackgroundWorkspaceLoadIds
            .map(\.uuidString)
            .sorted()
    }

    func primePendingBackgroundWorkspaces(tabManager: TabManager) async {
        await primePendingBackgroundWorkspaces(host: tabManager)
    }

    func primePendingBackgroundWorkspaces(host: any BackgroundWorkspacePrimeHosting) async {
        var schedule = BackgroundWorkspaceHeadlessPrimeSchedule<UUID>()

        while !Task.isCancelled {
            let workspaceIds = host.pendingBackgroundWorkspaceLoadIds
                .sorted { $0.uuidString < $1.uuidString }
            guard let workspaceId = schedule.nextWorkspaceID(
                orderedPendingWorkspaceIDs: workspaceIds
            ) else {
                return
            }
            let reason = await primeBackgroundWorkspaceIfNeeded(
                workspaceId: workspaceId,
                host: host
            )
            guard !Task.isCancelled else {
                schedule.resolve(workspaceID: workspaceId, resolution: .cancelled)
                return
            }

            switch reason {
            case .timeout:
                schedule.resolve(workspaceID: workspaceId, resolution: .timeout)
            case .cancelled:
                schedule.resolve(workspaceID: workspaceId, resolution: .cancelled)
                return
            case .workspaceRemoved:
                schedule.resolve(workspaceID: workspaceId, resolution: .workspaceRemoved)
            case .alreadyCleared, .noSurfaceWork, .surfaceReady:
                schedule.resolve(workspaceID: workspaceId, resolution: .completed)
            }
        }
    }

    private func primeBackgroundWorkspaceIfNeeded(
        workspaceId: UUID,
        host: any BackgroundWorkspacePrimeHosting
    ) async -> PrimeCompletionReason {
        guard host.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else {
            return .alreadyCleared
        }

        switch host.backgroundWorkspacePrimeWorkState(for: workspaceId) {
        case .workspaceRemoved:
            host.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .workspaceRemoved
        case .noSurfaceWork:
            host.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .noSurfaceWork
        case .ready:
            host.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .surfaceReady
        case .needsSurfaceStart:
            break
        }

        // CmuxTerminal starts deferred terminal runtimes in its own invisible AppKit host.
        // The coordinator can therefore start the runtime without building a background
        // SwiftUI workspace tree.

#if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        cmuxDebugLog("workspace.backgroundPrime.start workspace=\(workspaceId.uuidString.prefix(5))")
#endif

        let completionReason: PrimeCompletionReason
        switch stepBackgroundWorkspacePrime(workspaceId: workspaceId, host: host) {
        case .completed(let reason):
            completionReason = reason
        case .pending:
            completionReason = await waitForBackgroundWorkspacePrimeCompletion(
                workspaceId: workspaceId,
                host: host
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

    private func stepBackgroundWorkspacePrime(
        workspaceId: UUID,
        host: any BackgroundWorkspacePrimeHosting
    ) -> PrimeState {
        guard host.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else {
            return .completed(reason: .alreadyCleared)
        }

        switch host.backgroundWorkspacePrimeWorkState(for: workspaceId) {
        case .workspaceRemoved:
            host.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .completed(reason: .workspaceRemoved)
        case .noSurfaceWork:
            host.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .completed(reason: .noSurfaceWork)
        case .ready:
            host.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .completed(reason: .surfaceReady)
        case .needsSurfaceStart:
            break
        }

        host.requestBackgroundWorkspacePrimeSurfaceStart(for: workspaceId)

        switch host.backgroundWorkspacePrimeWorkState(for: workspaceId) {
        case .workspaceRemoved:
            host.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .completed(reason: .workspaceRemoved)
        case .noSurfaceWork:
            host.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .completed(reason: .noSurfaceWork)
        case .needsSurfaceStart:
            return .pending
        case .ready:
            host.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .completed(reason: .surfaceReady)
        }
    }

    private func waitForBackgroundWorkspacePrimeCompletion(
        workspaceId: UUID,
        host: any BackgroundWorkspacePrimeHosting
    ) async -> PrimeCompletionReason {
        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PrimeCompletionReason, Never>) in
                waiter.start(continuation: continuation)
                guard !waiter.isResolved else { return }

                installReadinessObservers(
                    waiter: waiter,
                    workspaceId: workspaceId,
                    host: host
                )

                let timeoutSleep = self.timeoutSleep
                let timeoutTask = Task { @MainActor [weak self, weak waiter, weak host] in
                    do {
                        try await timeoutSleep()
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, let self, let waiter, let host else { return }
                    if case .completed(let reason) = self.stepBackgroundWorkspacePrime(
                        workspaceId: workspaceId,
                        host: host
                    ) {
                        waiter.finish(reason: reason)
                    } else {
                        waiter.finish(reason: .timeout)
                    }
                }
                waiter.addTask(timeoutTask)

                evaluate(waiter: waiter, workspaceId: workspaceId, host: host)
            }
        } onCancel: {
            waiter.finish(reason: .cancelled)
        }
    }

    private func installReadinessObservers(
        waiter: Waiter,
        workspaceId: UUID,
        host: any BackgroundWorkspacePrimeHosting
    ) {
        let readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { [weak self, weak waiter, weak host] notification in
            guard let readyWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                  readyWorkspaceId == workspaceId,
                  let self,
                  let waiter,
                  let host else { return }
            Task { @MainActor in
                self.evaluate(waiter: waiter, workspaceId: workspaceId, host: host)
            }
        }
        waiter.addObserver(readyObserver)

        let hostedViewObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { [weak self, weak waiter, weak host] notification in
            guard let readyWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                  readyWorkspaceId == workspaceId,
                  let self,
                  let waiter,
                  let host else { return }
            Task { @MainActor in
                self.evaluate(waiter: waiter, workspaceId: workspaceId, host: host)
            }
        }
        waiter.addObserver(hostedViewObserver)

        let pendingObserver = host.backgroundWorkspacePrimePendingPublisher
            .dropFirst()
            .sink { [weak self, weak waiter, weak host] pendingIds in
                guard !pendingIds.contains(workspaceId),
                      let self,
                      let waiter,
                      let host else { return }
                Task { @MainActor in
                    self.evaluate(waiter: waiter, workspaceId: workspaceId, host: host)
                }
            }
        waiter.addCancellable(pendingObserver)

        let tabsObserver = host.backgroundWorkspacePrimeWorkspaceIDsPublisher
            .dropFirst()
            .sink { [weak self, weak waiter, weak host] workspaceIDs in
                guard !workspaceIDs.contains(workspaceId),
                      let self,
                      let waiter,
                      let host else { return }
                Task { @MainActor in
                    self.evaluate(waiter: waiter, workspaceId: workspaceId, host: host)
                }
            }
        waiter.addCancellable(tabsObserver)
    }

    private func evaluate(
        waiter: Waiter,
        workspaceId: UUID,
        host: any BackgroundWorkspacePrimeHosting
    ) {
        switch stepBackgroundWorkspacePrime(workspaceId: workspaceId, host: host) {
        case .pending:
            break
        case .completed(let reason):
            waiter.finish(reason: reason)
        }
    }
}

extension TabManager: BackgroundWorkspacePrimeHosting {
    var backgroundWorkspacePrimePendingPublisher: AnyPublisher<Set<UUID>, Never> {
        $pendingBackgroundWorkspaceLoadIds.eraseToAnyPublisher()
    }

    var backgroundWorkspacePrimeWorkspaceIDsPublisher: AnyPublisher<Set<UUID>, Never> {
        tabsPublisher
            .map { Set($0.map(\.id)) }
            .eraseToAnyPublisher()
    }

    func backgroundWorkspacePrimeWorkState(for workspaceID: UUID) -> BackgroundWorkspacePrimeWorkState {
        guard let workspace = tabs.first(where: { $0.id == workspaceID }) else {
            return .workspaceRemoved
        }
        guard workspace.hasBackgroundPrimeTerminalSurfaceStartWork() else {
            return .noSurfaceWork
        }
        guard !workspace.hasLoadedBackgroundPrimeTerminalSurface() else {
            return .ready
        }
        return .needsSurfaceStart
    }

    func requestBackgroundWorkspacePrimeSurfaceStart(for workspaceID: UUID) {
        tabs.first(where: { $0.id == workspaceID })?
            .requestBackgroundPrimeTerminalSurfaceStartIfNeeded()
    }
}
