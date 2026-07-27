/// The daemon's `POST /_subrouter/switch-account` outcome.
public struct SubrouterRemoteSwitchResult: Sendable, Hashable, Codable {
    /// Whether the server-side switch succeeded.
    public var ok: Bool

    private enum CodingKeys: String, CodingKey {
        case ok
    }

    /// Creates a result (tests and previews).
    /// - Parameter ok: Whether the switch succeeded.
    public init(ok: Bool) {
        self.ok = ok
    }
}
