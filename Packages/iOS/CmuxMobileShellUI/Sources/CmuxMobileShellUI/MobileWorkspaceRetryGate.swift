#if os(iOS)
import Foundation

/// Serializes empty-state recovery operations. A timed-out UI wait can release
/// its button without allowing a cancellation-ignoring refresh to overlap the
/// next attempt.
actor MobileWorkspaceRetryGate {
    private var isRunning = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        let waiterID = UUID()
        while isRunning {
            guard !Task.isCancelled else { return }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if !isRunning || Task.isCancelled {
                        continuation.resume()
                    } else {
                        waiters[waiterID] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            }
        }
        guard !Task.isCancelled else { return }
        isRunning = true
        await operation()
        isRunning = false
        if let next = waiters.first {
            waiters.removeValue(forKey: next.key)
            next.value.resume()
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume()
    }
}
#endif
