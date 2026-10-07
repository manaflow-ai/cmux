/// A device the host's trust store allows: its install id names its overlay
/// address (transport.md 3.1).
public struct WireGuardAuthorizedPeer: Sendable, Hashable {
    public var installID: String

    public init(installID: String) {
        self.installID = installID
    }
}
