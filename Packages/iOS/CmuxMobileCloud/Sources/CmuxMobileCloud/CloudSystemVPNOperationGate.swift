import Foundation

/// Serializes side effects that can outlive the task waiting for them.
///
/// Cancelling a caller must not release the slot while Network Extension or
/// Cloud work is still running. The next operation waits for the actual call
/// to return, so replacement intents cannot overlap an older one. A timed-out
/// owner gets a bounded grace period before its platform cancellation hook runs,
/// and its queue turn is released only when the underlying call returns.
@MainActor
final class CloudSystemVPNOperationGate {
    private var tail: Task<Void, Never>?
    private var pendingCount = 0

    var hasPendingOperation: Bool { pendingCount > 0 }

    func waitForIdle() async {
        await tail?.value
    }

    @MainActor
    fileprivate final class State {
        var acquired = false
        var cancelledBeforeAcquisition = false
        var finished = false
        var abandonmentTask: Task<Void, Never>?
    }

    @MainActor
    struct Operation<T: Sendable> {
        let acquired: Task<Void, Never>
        let result: Task<T, any Error>
        private let current: Task<T, any Error>
        private let state: State
        private let turn: Turn

        fileprivate init(
            acquired: Task<Void, Never>,
            result: Task<T, any Error>,
            current: Task<T, any Error>,
            state: State,
            turn: Turn
        ) {
            self.acquired = acquired
            self.result = result
            self.current = current
            self.state = state
            self.turn = turn
        }

        func cancelIfPending() {
            guard !state.acquired, !state.finished else { return }
            state.cancelledBeforeAcquisition = true
            current.cancel()
        }

        @discardableResult
        func abandonIfAcquired(
            after grace: Duration,
            onCancellation: @escaping @MainActor () -> Void
        ) -> Bool {
            guard state.acquired, !state.finished else { return false }
            state.abandonmentTask = Task { @MainActor in
                do {
                    try await ContinuousClock().sleep(for: grace)
                } catch {
                    return
                }
                guard !state.finished else { return }
                onCancellation()
                current.cancel()
            }
            return true
        }
    }

    @MainActor
    fileprivate final class Turn {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }

        func release() {
            guard !released else { return }
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    func start<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) -> Operation<T> {
        pendingCount += 1
        let predecessor = tail
        let state = State()
        let turn = Turn()
        let acquired = Task { @MainActor in
            if let predecessor {
                await predecessor.value
            }
        }
        let current = Task { @MainActor [weak self] in
            defer { self?.finish(state: state, turn: turn) }
            await acquired.value
            guard !state.cancelledBeforeAcquisition else {
                throw CancellationError()
            }
            state.acquired = true
            return try await operation()
        }
        tail = Task { @MainActor in await turn.wait() }
        let result = Task { @MainActor in
            try await current.value
        }
        return Operation(
            acquired: acquired,
            result: result,
            current: current,
            state: state,
            turn: turn
        )
    }

    private func finish(state: State, turn: Turn) {
        guard !state.finished else { return }
        state.finished = true
        state.abandonmentTask?.cancel()
        pendingCount -= 1
        turn.release()
    }
}
