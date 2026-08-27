import Foundation

/// Bounds concurrent notification-sound codec conversions.
///
/// The limiter owns an async waiter queue instead of blocking a cooperative
/// executor with a semaphore. Canceled waiters are removed and resumed
/// promptly, while each admitted operation releases its permit even when the
/// codec process fails or is canceled.
actor NotificationSoundConversionLimiter {
    private enum AdmissionError: Error, Sendable {
        case queueFull
    }

    private enum AdmissionResult: Sendable {
        case granted
        case canceled
        case queueFull
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<AdmissionResult, Never>
    }

    private let limit: Int
    private let queueLimit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int, queueLimit: Int = 64) {
        self.limit = max(1, limit)
        self.queueLimit = max(0, queueLimit)
    }

    /// Runs one operation while holding a conversion permit.
    func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        switch await acquire() {
        case .granted:
            defer { release() }
            return try await operation()
        case .canceled:
            throw CancellationError()
        case .queueFull:
            throw AdmissionError.queueFull
        }
    }

    private func acquire() async -> AdmissionResult {
        guard !Task.isCancelled else { return .canceled }
        if activeCount < limit {
            activeCount += 1
            return .granted
        }
        guard waiters.count < queueLimit else { return .queueFull }

        let waiterID = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation can happen between the initial check and the
                // continuation registration. Handle it synchronously so the
                // cancellation callback never has to win a timing race.
                if Task.isCancelled {
                    continuation.resume(returning: AdmissionResult.canceled)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        guard case .granted = result else { return result }

        // A permit may be granted immediately before cancellation becomes
        // observable to this task. Return it before reporting cancellation.
        if Task.isCancelled {
            release()
            return .canceled
        }
        return .granted
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: .canceled)
    }

    private func release() {
        guard activeCount > 0 else { return }
        guard !waiters.isEmpty else {
            activeCount -= 1
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: .granted)
    }
}
