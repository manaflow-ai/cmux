import Foundation

/// Serializes side effects that can outlive the task waiting for them.
///
/// Cancelling a caller must not release the slot while Network Extension or
/// Cloud work is still running. The next operation waits for the actual call
/// to return, so replacement intents cannot overlap an older one. A queued
/// operation can be cancelled before it acquires the slot.
@MainActor
final class CloudSystemVPNOperationGate {
    private var tail: Task<Void, Never>?
    private var pendingCount = 0

    var hasPendingOperation: Bool { pendingCount > 0 }

    @MainActor
    fileprivate final class State {
        var acquired = false
        var cancelledBeforeAcquisition = false
    }

    @MainActor
    struct Operation<T: Sendable> {
        let acquired: Task<Void, Never>
        let result: Task<T, any Error>
        private let state: State

        fileprivate init(
            acquired: Task<Void, Never>,
            result: Task<T, any Error>,
            state: State
        ) {
            self.acquired = acquired
            self.result = result
            self.state = state
        }

        func cancelIfPending() {
            guard !state.acquired else { return }
            state.cancelledBeforeAcquisition = true
        }
    }

    func start<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) -> Operation<T> {
        pendingCount += 1
        let predecessor = tail
        let state = State()
        let acquired = Task { @MainActor in
            if let predecessor {
                await predecessor.value
            }
        }
        let current = Task { @MainActor [weak self] in
            defer { self?.pendingCount -= 1 }
            await acquired.value
            guard !state.cancelledBeforeAcquisition else {
                throw CancellationError()
            }
            state.acquired = true
            return try await operation()
        }
        tail = Task { @MainActor in
            _ = await current.result
        }
        let result = Task { @MainActor in
            try await current.value
        }
        return Operation(acquired: acquired, result: result, state: state)
    }
}
