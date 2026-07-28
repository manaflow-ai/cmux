/// A participant snapshot sent by the relay.
public struct ShareParticipant: Codable, Equatable, Sendable {
    /// Stable relay user identifier.
    public var user: String

    /// Participant email shown to the host.
    public var email: String

    /// Current host-authorized role.
    public var role: ShareRole

    /// Index in the protocol's shared participant color palette.
    public var color: Int

    /// Workspace the participant is following, when any.
    public var focusWs: String?

    /// Whether the participant currently has a relay connection.
    public var connected: Bool

    /// Whether this participant is the host.
    public var isHost: Bool

    /// Creates a participant snapshot.
    public init(
        user: String,
        email: String,
        role: ShareRole,
        color: Int,
        focusWs: String?,
        connected: Bool,
        isHost: Bool
    ) {
        self.user = user
        self.email = email
        self.role = role
        self.color = color
        self.focusWs = focusWs
        self.connected = connected
        self.isHost = isHost
    }
}
