/// One team the signed-in user belongs to, as a typed, `Sendable` snapshot read
/// off the live auth coordinator through ``AuthStatusReading``.
///
/// Encoded into each element of the wire `teams` array by ``ControlAuthWorker``
/// exactly as the legacy `v2AuthStatusPayload` did: `id` and `display_name` are
/// always present; `slug` is omitted when absent.
public struct ControlAuthTeam: Sendable, Equatable {
    /// The team id (wire key `id`).
    public let id: String
    /// The team display name (wire key `display_name`).
    public let displayName: String
    /// The team slug, or `nil` to omit the wire `slug` key.
    public let slug: String?

    /// Creates a team snapshot.
    ///
    /// - Parameters:
    ///   - id: The team id.
    ///   - displayName: The display name.
    ///   - slug: The slug, or `nil` when absent.
    public init(id: String, displayName: String, slug: String?) {
        self.id = id
        self.displayName = displayName
        self.slug = slug
    }
}
