internal import Foundation

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
    /// The coordinator calls this only after slot admission, so buffered
    /// submissions never create threads. Each admitted Task creates one Thread,
    /// runs one blocking free, resumes once, and lets that Thread return.
    nonisolated func prepare(
        operation: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable () async -> Void
    ) -> TerminalSurfaceRuntimePreparedTeardownExecution {
        let startGate = TerminalSurfaceRuntimeTeardownStartGate()
        let task = Task(priority: .utility) {
            await startGate.wait()
            await withCheckedContinuation { continuation in
                let thread = Thread {
                    operation()
                    continuation.resume()
                }
                thread.name = "com.cmux.runtime-teardown"
                thread.qualityOfService = .utility
                thread.start()
            }
            await completion()
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
