/// Namespace in which a Feed event's agent process identifier is meaningful.
public enum WorkstreamProcessNamespace: String, Codable, Sendable, Equatable {
    /// The PID belongs to this macOS host and may be observed with Darwin process APIs.
    case local
    /// The PID belongs to a relayed remote host and is opaque on this macOS host.
    case remote
    /// The sender supplied malformed or unsupported namespace metadata.
    case unknown
}
