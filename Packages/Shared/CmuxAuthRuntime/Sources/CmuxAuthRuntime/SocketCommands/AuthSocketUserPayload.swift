/// A socket-safe user summary for `auth.status`.
public struct AuthSocketUserPayload: Sendable, Equatable {
    /// The Stack Auth user id.
    public let id: String
    /// The user's primary email, if one is set.
    public let email: String?
    /// The user's display name, if one is set.
    public let displayName: String?

    /// Creates a socket user payload.
    ///
    /// - Parameters:
    ///   - id: The Stack Auth user id.
    ///   - email: The user's primary email, if one is set.
    ///   - displayName: The user's display name, if one is set.
    public init(id: String, email: String?, displayName: String?) {
        self.id = id
        self.email = email
        self.displayName = displayName
    }
}
