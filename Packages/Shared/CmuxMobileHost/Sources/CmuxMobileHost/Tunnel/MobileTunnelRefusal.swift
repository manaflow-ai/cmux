/// Why `tcp.forward` refused a port.
public enum MobileTunnelRefusal: Error, Hashable, Sendable {
    /// Below 1024.
    case privileged
    /// In the configuration's denied set.
    case denied
    /// Not a detected workspace listener and not allowed by the user, right now.
    case notAdvertised

    public var code: String { "tunnel.port_not_allowed" }

    public var reason: String {
        switch self {
        case .privileged: "privileged"
        case .denied: "denied"
        case .notAdvertised: "not_advertised"
        }
    }
}
