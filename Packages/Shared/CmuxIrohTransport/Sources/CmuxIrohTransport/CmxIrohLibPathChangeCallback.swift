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
        guard failClosedOnOverflow else { return }
        if case .dropped = result {
            continuation.finish()
        }
    }
}
