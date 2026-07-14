/// One event stream's render-grid demand semantics.
public enum MobileRenderGridDemandScope: Equatable, Sendable {
    /// Compatibility behavior for a client that subscribed before demand v1.
    case legacyAll
    /// Explicit focused and preview demand from a v1-capable client.
    case scoped(MobileRenderGridDemand)
}
