import Foundation

/// Serializes side effects that can outlive the task waiting for them.
///
/// Cancelling a caller must not release the slot while Network Extension or
/// Cloud work is still running. The next operation waits for the actual call
/// to return, so replacement intents cannot overlap an older one.
@MainActor
final class CloudSystemVPNOperationGate {
    private var tail: Task<Void, Never>?
    private var pendingCount = 0

    var hasPendingOperation: Bool { pendingCount > 0 }

    struct Operation<T: Sendable>: Sendable {
        let acquired: Task<Void, Never>
        let result: Task<T, any Error>
    }

    func start<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) -> Operation<T> {
        pendingCount += 1
        let predecessor = tail
        let acquired = Task { @MainActor in
            if let predecessor {
                await predecessor.value
            }
        }
        let current = Task { @MainActor [weak self] in
            defer { self?.pendingCount -= 1 }
            await acquired.value
            return try await operation()
        }
        tail = Task { @MainActor in
            _ = await current.result
        }
        let result = Task { @MainActor in
            try await current.value
        }
        return Operation(acquired: acquired, result: result)
    }
}
