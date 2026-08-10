internal import os

/// Selects the ownership boundary for a native surface free.
nonisolated enum TerminalSurfaceRuntimeTeardownExecutionLane: Sendable {
    /// Uses the bounded, failure-isolated close worker pool.
    case boundedClose

    /// Gives an explicitly owned hibernation join an independent bounded slot.
    case isolatedHibernation

    /// Creates the one Task that owns a slot's native free.
    ///
    /// The checked-continuation gate makes storage happen before execution. It
    /// intentionally does not treat Task cancellation as permission to skip a
    /// native free, because the request owns the surface until free completes.
    nonisolated func prepare(
        operation: @escaping @Sendable () async -> Void
    ) -> TerminalSurfaceRuntimePreparedTeardownExecution {
        let startGate = TerminalSurfaceRuntimeTeardownStartGate()
        let task = Task.detached(priority: .utility) {
            await startGate.wait()
            await operation()
        }
        return TerminalSurfaceRuntimePreparedTeardownExecution(
            task: task,
            startGate: startGate
        )
    }
}

/// A native-free Task that cannot run before its coordinator stores the handle.
nonisolated struct TerminalSurfaceRuntimePreparedTeardownExecution: Sendable {
    let task: Task<Void, Never>
    private let startGate: TerminalSurfaceRuntimeTeardownStartGate

    fileprivate init(
        task: Task<Void, Never>,
        startGate: TerminalSurfaceRuntimeTeardownStartGate
    ) {
        self.task = task
        self.startGate = startGate
    }

    func start() {
        startGate.start()
    }
}

private final class TerminalSurfaceRuntimeTeardownStartGate: @unchecked Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Void, Never>)
        case started
    }

    private let state = OSAllocatedUnfairLock(initialState: State.pending)

    func wait() async {
        await withCheckedContinuation { continuation in
            let startImmediately = state.withLock { state in
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    return false
                case .started:
                    return true
                case .waiting:
                    preconditionFailure("teardown start gate waited more than once")
                }
            }
            if startImmediately {
                continuation.resume()
            }
        }
    }

    func start() {
        let continuation = state.withLock { state in
            switch state {
            case .pending:
                state = .started
                return nil
            case .waiting(let continuation):
                state = .started
                return continuation
            case .started:
                return nil
            }
        }
        continuation?.resume()
    }
}
