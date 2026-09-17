public import Foundation

/// Renderer-only events routed to the exact visible workspace presentation.
public enum BackendRendererLifecycleEvent: Equatable, Sendable {
    case workerChanged(BackendRendererWorkerChanged)
    case presentationReady(BackendRendererPresentationReady)
    case configInvalidated(BackendRendererConfigInvalidated)
}

/// One locally keyed renderer event stream owned by a visible presentation.
public struct BackendRendererEventSubscription: Sendable {
    public let identifier: UUID
    public let events: AsyncStream<BackendRendererLifecycleEvent>

    public init(
        identifier: UUID,
        events: AsyncStream<BackendRendererLifecycleEvent>
    ) {
        self.identifier = identifier
        self.events = events
    }
}
