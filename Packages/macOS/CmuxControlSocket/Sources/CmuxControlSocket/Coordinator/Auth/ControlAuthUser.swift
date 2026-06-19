/// The signed-in user fields the `auth.status` payload carries, as a typed,
/// `Sendable` snapshot read off the live auth coordinator through
/// ``AuthStatusReading``.
///
/// Encoded into the wire `user` object by ``ControlAuthWorker`` exactly as the
/// legacy `v2AuthStatusPayload` did: `id` is always present; `email` is omitted
/// when the user has no primary email; `display_name` is omitted when absent.
public struct ControlAuthUser: Sendable, Equatable {
    /// The stable user id (wire key `id`).
    public let id: String
    /// The user's primary email, or `nil` to omit the wire `email` key.
    public let email: String?
    /// The user's display name, or `nil` to omit the wire `display_name` key.
    public let displayName: String?

    /// Creates a user snapshot.
    ///
    /// - Parameters:
    ///   - id: The user id.
    ///   - email: The primary email, or `nil` when absent.
    ///   - displayName: The display name, or `nil` when absent.
    public init(id: String, email: String?, displayName: String?) {
        self.id = id
        self.email = email
        self.displayName = displayName
    }
}
