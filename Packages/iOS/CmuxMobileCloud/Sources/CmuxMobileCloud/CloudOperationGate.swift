import Foundation

/// Serializes side effects that can outlive the task waiting for them.
///
/// Cancelling a caller must not release the slot while Network Extension or
/// Cloud work is still running. The next operation waits for the actual call
/// to return, so replacement intents cannot overlap an older one. A timed-out
/// owner gets a bounded grace period before its platform cancellation hook runs,
/// and its queue turn is released only when the underlying call returns.
@MainActor
final class CloudOperationGate {
    private var tail: Task<Void, Never>?
    private var pendingCount = 0

    var hasPendingOperation: Bool { pendingCount > 0 }

    func waitForIdle() async {
        await tail?.value
    }

    func start<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) -> Operation<T> {
        startLeased { _ in try await operation() }
    }

    func startLeased<T: Sendable>(
        _ operation: @escaping @MainActor (HoldFactory) async throws -> T
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
            guard self != nil else {
                throw CancellationError()
            }
            state.acquired = true
            let makeHold: HoldFactory = { [weak self, weak state] in
                guard let self, let state else {
                    return Hold {}
                }
                return self.makeHold(state: state, turn: turn)
            }
            return try await operation(makeHold)
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

    private func makeHold(state: State, turn: Turn) -> Hold {
        let id = UUID()
        state.activeHoldIDs.insert(id)
        return Hold { [weak self, state] in
            Task { @MainActor in
                guard let self else { return }
                state.activeHoldIDs.remove(id)
                self.finishIfReady(state: state, turn: turn)
            }
        }
    }

    private func finish(state: State, turn: Turn) {
        guard !state.operationFinished else { return }
        state.operationFinished = true
        state.abandonmentTask?.cancel()
        finishIfReady(state: state, turn: turn)
    }

    private func finishIfReady(state: State, turn: Turn) {
        guard !state.finished, state.operationFinished, state.activeHoldIDs.isEmpty else { return }
        state.finished = true
        pendingCount -= 1
        turn.release()
    }
}

extension CloudOperationGate {
    typealias HoldFactory = @MainActor @Sendable () -> Hold

    /// Keeps the gate occupied after the operation result is returned.
    /// Attachments release this when their stream is detached or deallocated.
    final class Hold: @unchecked Sendable {
        private let onRelease: @Sendable () -> Void

        init(_ onRelease: @escaping @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        func release() {
            onRelease()
        }

        deinit {
            onRelease()
        }
    }
}
