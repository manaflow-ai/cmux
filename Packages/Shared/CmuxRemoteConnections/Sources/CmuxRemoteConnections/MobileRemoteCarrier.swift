/// The protocol that carries a remote terminal session.
public enum MobileRemoteCarrier: String, Codable, CaseIterable, Equatable, Sendable {
    /// Select an available carrier that satisfies the requested session capabilities.
    case automatic
    /// SSH over the operating system's routed TCP connection.
    case ssh
    /// Mosh, bootstrapped through SSH and continued over UDP.
    case mosh
    /// Eternal Terminal over its TCP session protocol.
    case eternalTerminal = "et"
}
