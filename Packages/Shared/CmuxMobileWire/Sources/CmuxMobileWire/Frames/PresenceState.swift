/// The body of `presence.set`.
public struct PresenceState: Hashable, Sendable, Codable {
    public var active: Bool
    /// Client kind, at most 16 characters (`ios`, `mac`).
    public var client: String

    public init(active: Bool, client: String) {
        self.active = active
        self.client = client
    }
}
