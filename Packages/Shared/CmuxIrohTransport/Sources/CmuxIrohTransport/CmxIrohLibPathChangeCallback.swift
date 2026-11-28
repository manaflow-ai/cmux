import IrohLib

/// Bridges Iroh's live path watcher into a coordinate-private async stream.
final class CmxIrohLibPathChangeCallback: PathChangeCallback, Sendable {
    private let continuation: AsyncStream<CmxIrohObservedConnectionPath>.Continuation

    init(continuation: AsyncStream<CmxIrohObservedConnectionPath>.Continuation) {
        self.continuation = continuation
    }

    func onChange(paths: [PathSnapshot]) async {
        continuation.yield(
            CmxIrohObservedConnectionPath(
                snapshots: paths.map(CmxIrohConnectionPathSnapshot.init)
            )
        )
    }
}
