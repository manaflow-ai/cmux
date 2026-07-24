/// The receiving connection's identity within a session snapshot.
public struct ShareSelfIdentity: Codable, Equatable, Sendable {
    /// Stable relay user identifier.
    public var user: String

    /// Current host-authorized role.
    public var role: ShareRole

    /// Index in the shared participant color palette.
    public var color: Int

    /// Whether this connection belongs to the host.
    public var isHost: Bool

    /// Creates a self-identity snapshot.
    public init(user: String, role: ShareRole, color: Int, isHost: Bool) {
        self.user = user
        self.role = role
        self.color = color
        self.isHost = isHost
    }
}
