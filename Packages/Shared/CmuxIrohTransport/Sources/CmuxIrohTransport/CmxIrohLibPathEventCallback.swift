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
        let event = CmxIrohConnectionPathEvent(event)
        guard case .dropped = continuation.yield(event),
              event.kind != .lagged else { return }
        // The bounded stream protects the app if Iroh outpaces diagnostics.
        // Keep a redacted lag marker in the newest window whenever an older
        // event is evicted, matching Iroh's own `PathEvent.lagged` semantics.
        _ = continuation.yield(CmxIrohConnectionPathEvent(
            kind: .lagged,
            pathKind: .unknown
        ))
    }
}
