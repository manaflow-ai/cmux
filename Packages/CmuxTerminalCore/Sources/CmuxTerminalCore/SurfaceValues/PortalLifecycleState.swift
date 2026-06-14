/// The lifecycle phase of a surface with respect to its portal host.
public enum PortalLifecycleState: String, Sendable {
    /// The surface is alive and may be hosted.
    case live
    /// Teardown has begun; new host leases are rejected.
    case closing
    /// Teardown finished; the surface can never be hosted again.
    case closed
}
