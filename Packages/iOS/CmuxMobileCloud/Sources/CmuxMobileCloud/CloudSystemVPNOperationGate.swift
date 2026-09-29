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
    private var quarantined = false

    var hasPendingOperation: Bool { pendingCount > 0 }

    func waitForIdle() async {
        await tail?.value
    }

    func start<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) -> Operation<T> {
        pendingCount += 1
        let predecessor = tail
        let state = State()
        let turn = Turn()
        let abandon: @MainActor () -> Void = { [weak self] in
            self?.abandon(state: state, turn: turn)
        }
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
            guard let self, !self.quarantined else {
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
            turn: turn,
            abandon: abandon
        )
    }

    private func abandon(state: State, turn: Turn) {
        guard !state.finished else { return }
        state.finished = true
        pendingCount -= 1
        quarantined = true
        turn.release()
    }

    private func finish(state: State, turn: Turn) {
        if state.finished {
            if state.cancellationRequested {
                quarantined = false
            }
            return
        }
        state.finished = true
        state.abandonmentTask?.cancel()
        if state.cancellationRequested {
            quarantined = false
        }
        pendingCount -= 1
        turn.release()
    }
}
