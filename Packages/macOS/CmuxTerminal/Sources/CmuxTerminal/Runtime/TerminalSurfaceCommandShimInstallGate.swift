internal import Foundation

/// Limits command-shim installation to one live operation per runtime
/// filesystem owner, including an installer that does not stop on cancellation.
/// After an active deadline expires, new work is rejected until that installer
/// returns and releases its filesystem ownership.
public actor TerminalSurfaceCommandShimInstallGate {
    private let maximumWaiterCount: Int
    private var activeToken: UUID?
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<UUID?, Never>] = [:]
    private var rejectsAcquisitionsUntilRelease = false

    /// Creates an idle install gate with a fixed pending-work limit.
    ///
    /// - Parameter maximumWaiterCount: The maximum number of installs that can
    ///   wait behind the active installer. A nonpositive value disables
    ///   waiting, and additional work is rejected.
    public init(maximumWaiterCount: Int = 64) {
        self.maximumWaiterCount = max(0, maximumWaiterCount)
    }

    func acquire() async -> UUID? {
        await acquire(onQueued: {})
    }

    func acquire(
        onQueued: @escaping @Sendable () -> Void
    ) async -> UUID? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(
                    waiterID: waiterID,
                    continuation: continuation,
                    onQueued: onQueued
                )
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    func release(_ token: UUID) {
        guard activeToken == token else { return }
        activeToken = nil
        if rejectsAcquisitionsUntilRelease {
            rejectsAcquisitionsUntilRelease = false
            return
        }
        while !waiterOrder.isEmpty {
            let waiterID = waiterOrder.removeFirst()
            guard let continuation = waiters.removeValue(forKey: waiterID) else {
                continue
            }
            let nextToken = UUID()
            activeToken = nextToken
            continuation.resume(returning: nextToken)
            return
        }
    }

    func rejectAcquisitions(untilReleaseOf token: UUID) {
        guard activeToken == token else { return }
        rejectsAcquisitionsUntilRelease = true
        let rejectedContinuations = waiters.values
        waiterOrder.removeAll(keepingCapacity: true)
        waiters.removeAll(keepingCapacity: true)
        for continuation in rejectedContinuations {
            continuation.resume(returning: nil)
        }
    }

    private func enqueue(
        waiterID: UUID,
        continuation: CheckedContinuation<UUID?, Never>,
        onQueued: @escaping @Sendable () -> Void
    ) {
        guard !rejectsAcquisitionsUntilRelease else {
            continuation.resume(returning: nil)
            return
        }
        guard activeToken != nil else {
            let token = UUID()
            activeToken = token
            continuation.resume(returning: token)
            return
        }
        guard waiters.count < maximumWaiterCount else {
            continuation.resume(returning: nil)
            return
        }
        waiterOrder.append(waiterID)
        waiters[waiterID] = continuation
        onQueued()
    }

    private func cancel(waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else {
            return
        }
        waiterOrder.removeAll { $0 == waiterID }
        continuation.resume(returning: nil)
    }
}
