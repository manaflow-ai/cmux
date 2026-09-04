import IrohLib

/// Bridges Iroh's live path watcher into a coordinate-private async stream.
final class CmxIrohLibPathChangeCallback: PathChangeCallback, Sendable {
    private let continuation: AsyncStream<CmxIrohObservedConnectionPath>.Continuation
    private let failClosedOnOverflow: Bool

    init(
        continuation: AsyncStream<CmxIrohObservedConnectionPath>.Continuation,
        failClosedOnOverflow: Bool = false
    ) {
        self.continuation = continuation
        self.failClosedOnOverflow = failClosedOnOverflow
    }

    func onChange(paths: [PathSnapshot]) async {
        let result = continuation.yield(
            CmxIrohObservedConnectionPath(
                snapshots: paths.map(CmxIrohConnectionPathSnapshot.init)
            )
        )
        guard failClosedOnOverflow, case .dropped = result else { return }
        // A policy stream may not silently lose a transition: if the consumer
        // falls behind its bounded window, publish an explicit unknown state
        // and terminate. The peer-session policy check treats unknown as
        // forbidden and tears down the session, preserving fail-closed
        // semantics without unbounded memory growth.
        _ = continuation.yield(.unknown)
        continuation.finish()
    }
}
