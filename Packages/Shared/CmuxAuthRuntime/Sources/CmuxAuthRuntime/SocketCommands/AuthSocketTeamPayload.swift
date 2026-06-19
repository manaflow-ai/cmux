/// A socket-safe team summary for `auth.status`.
public struct AuthSocketTeamPayload: Sendable, Equatable {
    /// The Stack Auth team id.
    public let id: String
    /// The team's human-readable display name.
    public let displayName: String
    /// The team's URL slug, when the backend exposes one.
    public let slug: String?

    /// Creates a socket team payload.
    ///
    /// - Parameters:
    ///   - id: The Stack Auth team id.
    ///   - displayName: The team's human-readable display name.
    ///   - slug: The team's URL slug, when known.
    public init(id: String, displayName: String, slug: String?) {
        self.id = id
        self.displayName = displayName
        self.slug = slug
    }
}
