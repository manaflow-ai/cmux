
/// `cloud-session-needed`: the daemon asks for a new lease.

/// `cloud-session-needed`: the daemon asks for a new lease.
public struct CloudSessionNeeded: Decodable, Sendable, Hashable {
    /// `missing`, `expiring`, `expired` or `unauthenticated`.
    public var reason: String
    public var expiresAt: UInt64?

    public init(reason: String, expiresAt: UInt64? = nil) {
        self.reason = reason
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case reason
        case expiresAt = "expires_at"
    }
}
