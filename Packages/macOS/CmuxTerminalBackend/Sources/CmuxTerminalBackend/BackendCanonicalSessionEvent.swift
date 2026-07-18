/// Ordered canonical-state changes published by ``BackendCanonicalSession``.
public enum BackendCanonicalSessionEvent: Equatable, Sendable {
    /// The atomic snapshot installed before incremental delivery starts.
    case snapshot(TopologySnapshot)

    /// One validated contiguous transaction. Its replacement is the new complete state.
    case delta(TopologyDelta)

    /// A disposable renderer changed process identity and needs a fresh frame endpoint.
    case rendererWorkerChanged(BackendRendererWorkerChanged)

    /// Exact font-grid metrics produced by the worker for one render generation.
    case rendererPresentationReady(BackendRendererPresentationReady)

    /// The connection stopped and must be replaced before state can advance.
    case disconnected(BackendCanonicalSessionError)
}
