import CmuxTerminal
import Foundation

actor SurfaceReadTextReadinessWaiter {
    private let maxWaiters: Int
    private var waiters: [UUID: [UUID: SurfaceReadTextReadinessWaiterState]] = [:]
    private var observers: [UUID: NSObjectProtocol] = [:]
    private var activeWaiterCount = 0

    init(maxWaiters: Int) {
        self.maxWaiters = maxWaiters
    }

    func prepareWait(for surfaceID: UUID) -> SurfaceReadTextReadinessWait? {
        guard activeWaiterCount < maxWaiters else {
            return nil
        }

        let waiterID = UUID()
        var surfaceWaiters = waiters[surfaceID] ?? [:]
        surfaceWaiters[waiterID] = .pending
        waiters[surfaceID] = surfaceWaiters
        activeWaiterCount += 1
        installObserverIfNeeded(for: surfaceID)
        return SurfaceReadTextReadinessWait(surfaceID: surfaceID, waiterID: waiterID)
    }

    func wait(_ wait: SurfaceReadTextReadinessWait) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerContinuation(continuation, for: wait)
            }
        } onCancel: {
            Task {
                await self.cancel(wait)
            }
        }
    }

    func cancel(_ wait: SurfaceReadTextReadinessWait) {
        finish(wait, result: false)
    }

    private func installObserverIfNeeded(for surfaceID: UUID) {
        guard observers[surfaceID] == nil else { return }
        observers[surfaceID] = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard notification.userInfo?["surfaceId"] as? UUID == surfaceID else { return }
            Task {
                await self?.signalReady(surfaceID: surfaceID)
            }
        }
    }

    private func registerContinuation(
        _ continuation: CheckedContinuation<Bool, Never>,
        for wait: SurfaceReadTextReadinessWait
    ) {
        guard var surfaceWaiters = waiters[wait.surfaceID],
              let state = surfaceWaiters[wait.waiterID] else {
            continuation.resume(returning: false)
            return
        }

        switch state {
        case .pending:
            surfaceWaiters[wait.waiterID] = .waiting(continuation)
            waiters[wait.surfaceID] = surfaceWaiters
        case .ready:
            surfaceWaiters.removeValue(forKey: wait.waiterID)
            activeWaiterCount = max(0, activeWaiterCount - 1)
            updateSurfaceWaiters(surfaceWaiters, for: wait.surfaceID)
            continuation.resume(returning: true)
        case .waiting:
            continuation.resume(returning: false)
        }
    }

    private func signalReady(surfaceID: UUID) {
        guard let surfaceWaiters = waiters.removeValue(forKey: surfaceID) else {
            removeObserver(for: surfaceID)
            return
        }

        var continuations: [CheckedContinuation<Bool, Never>] = []
        var remainingWaiters: [UUID: SurfaceReadTextReadinessWaiterState] = [:]
        for (waiterID, state) in surfaceWaiters {
            switch state {
            case .pending, .ready:
                remainingWaiters[waiterID] = .ready
            case .waiting(let continuation):
                continuations.append(continuation)
            }
        }

        activeWaiterCount = max(0, activeWaiterCount - continuations.count)
        removeObserver(for: surfaceID)
        if !remainingWaiters.isEmpty {
            waiters[surfaceID] = remainingWaiters
        }
        for continuation in continuations {
            continuation.resume(returning: true)
        }
    }

    private func finish(_ wait: SurfaceReadTextReadinessWait, result: Bool) {
        guard var surfaceWaiters = waiters[wait.surfaceID],
              let state = surfaceWaiters.removeValue(forKey: wait.waiterID) else {
            return
        }

        let continuation: CheckedContinuation<Bool, Never>?
        switch state {
        case .pending, .ready:
            continuation = nil
        case .waiting(let waitingContinuation):
            continuation = waitingContinuation
        }

        activeWaiterCount = max(0, activeWaiterCount - 1)
        updateSurfaceWaiters(surfaceWaiters, for: wait.surfaceID)
        continuation?.resume(returning: result)
    }

    private func updateSurfaceWaiters(
        _ surfaceWaiters: [UUID: SurfaceReadTextReadinessWaiterState],
        for surfaceID: UUID
    ) {
        if surfaceWaiters.isEmpty {
            waiters.removeValue(forKey: surfaceID)
            removeObserver(for: surfaceID)
        } else {
            waiters[surfaceID] = surfaceWaiters
        }
    }

    private func removeObserver(for surfaceID: UUID) {
        guard let observer = observers.removeValue(forKey: surfaceID) else { return }
        NotificationCenter.default.removeObserver(observer)
    }
}
