import Foundation

/// Bounds concurrent attachment preparation across panels without owning any
/// panel request state. Each permit reserves a fixed 32 MiB accounting unit;
/// helper copies stream through a small buffer and durable bytes have a
/// separate storage quota.
actor TextBoxAttachmentPreparationBudget {
    typealias Limits = TextBoxAttachmentPreparationBudgetLimits
    typealias Permit = TextBoxAttachmentPreparationBudgetPermit
    typealias Snapshot = TextBoxAttachmentPreparationBudgetSnapshot

    private typealias ComposerUsage =
        TextBoxAttachmentPreparationBudgetComposerUsage
    private typealias Waiter = TextBoxAttachmentPreparationBudgetWaiter

    static let shared = TextBoxAttachmentPreparationBudget()

    private let limits: Limits
    private var globalConcurrentCount = 0
    private var globalReservedBytes = 0
    private var composerUsage: [UUID: ComposerUsage] = [:]
    private var activePermits: [UUID: Permit] = [:]
    private var waiters: [Waiter] = []

    init(limits: Limits = .production) {
        self.limits = limits
    }

    func acquire(composerID: UUID, reservedBytes: Int) async -> Permit? {
        guard reservedBytes > 0,
              reservedBytes <= limits.globalReservedBytes,
              reservedBytes <= limits.perComposerReservedBytes,
              limits.globalConcurrentCount > 0,
              limits.perComposerConcurrentCount > 0 else {
            return nil
        }

        let waiterID = UUID()
        let permit = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Permit?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if canGrant(composerID: composerID, reservedBytes: reservedBytes) {
                    continuation.resume(returning: reserve(
                        composerID: composerID,
                        reservedBytes: reservedBytes
                    ))
                } else if waiters.count >= limits.maximumQueuedCount {
                    continuation.resume(returning: nil)
                } else {
                    waiters.append(Waiter(
                        id: waiterID,
                        composerID: composerID,
                        reservedBytes: reservedBytes,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
        guard let permit else { return nil }
        guard !Task.isCancelled else {
            release(permit)
            return nil
        }
        return permit
    }

    func release(_ permit: Permit) {
        guard activePermits.removeValue(forKey: permit.id) == permit else { return }
        let composerID = permit.composerID
        let reservedBytes = permit.reservedBytes
        globalConcurrentCount = max(0, globalConcurrentCount - 1)
        globalReservedBytes = max(0, globalReservedBytes - reservedBytes)
        if var usage = composerUsage[composerID] {
            usage.concurrentCount = max(0, usage.concurrentCount - 1)
            usage.reservedBytes = max(0, usage.reservedBytes - reservedBytes)
            if usage.concurrentCount == 0, usage.reservedBytes == 0 {
                composerUsage.removeValue(forKey: composerID)
            } else {
                composerUsage[composerID] = usage
            }
        }
        drainWaiters()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            globalConcurrentCount: globalConcurrentCount,
            globalReservedBytes: globalReservedBytes,
            queuedCount: waiters.count
        )
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }

    private func canGrant(composerID: UUID, reservedBytes: Int) -> Bool {
        let usage = composerUsage[composerID] ?? ComposerUsage()
        return globalConcurrentCount < limits.globalConcurrentCount
            && usage.concurrentCount < limits.perComposerConcurrentCount
            && globalReservedBytes + reservedBytes <= limits.globalReservedBytes
            && usage.reservedBytes + reservedBytes <= limits.perComposerReservedBytes
    }

    private func reserve(
        composerID: UUID,
        reservedBytes: Int
    ) -> Permit {
        let permit = Permit(
            id: UUID(),
            composerID: composerID,
            reservedBytes: reservedBytes
        )
        globalConcurrentCount += 1
        globalReservedBytes += reservedBytes
        var usage = composerUsage[composerID] ?? ComposerUsage()
        usage.concurrentCount += 1
        usage.reservedBytes += reservedBytes
        composerUsage[composerID] = usage
        activePermits[permit.id] = permit
        return permit
    }

    private func drainWaiters() {
        while let index = waiters.firstIndex(where: {
            canGrant(composerID: $0.composerID, reservedBytes: $0.reservedBytes)
        }) {
            let waiter = waiters.remove(at: index)
            let permit = reserve(
                composerID: waiter.composerID,
                reservedBytes: waiter.reservedBytes
            )
            waiter.continuation.resume(returning: permit)
        }
    }
}
