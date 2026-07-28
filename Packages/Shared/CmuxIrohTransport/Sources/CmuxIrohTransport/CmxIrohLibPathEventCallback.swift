import IrohLib

/// Bridges Iroh's individual path watcher into a redacted async stream.
final class CmxIrohLibPathEventCallback: PathEventCallback, Sendable {
    private let continuation: AsyncStream<CmxIrohConnectionPathEvent>.Continuation

    init(
        continuation: AsyncStream<CmxIrohConnectionPathEvent>.Continuation
    ) {
        self.continuation = continuation
    }

    func onEvent(event: PathEvent) async {
        continuation.yield(CmxIrohConnectionPathEvent(event))
    }
}
