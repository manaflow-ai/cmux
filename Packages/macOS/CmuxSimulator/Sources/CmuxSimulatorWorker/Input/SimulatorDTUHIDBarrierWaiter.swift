import Foundation

/// Bridges libxpc's barrier callback into one cancellation-safe async result.
actor SimulatorDTUHIDBarrierWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var completedValue: Bool?

    func wait(
        start: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    ) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let completedValue {
                    continuation.resume(returning: completedValue)
                    return
                }
                self.continuation = continuation
                start { [weak self] value in
                    Task { await self?.complete(value) }
                }
            }
        } onCancel: {
            Task { await self.complete(false) }
        }
    }

    func complete(_ value: Bool) {
        guard completedValue == nil else { return }
        completedValue = value
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}
