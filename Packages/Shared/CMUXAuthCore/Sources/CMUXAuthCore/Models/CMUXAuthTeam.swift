import Foundation

/// A team the signed-in user belongs to.
///
/// Mirrors the Stack Auth team summary the apps surface in account UI and
/// expose over the cmux socket (`auth.status`). Codable so consumers can cache
/// the team list alongside the cached user.
public struct CMUXAuthTeam: Codable, Equatable, Identifiable, Sendable {
    /// The Stack Auth team id.
    public let id: String
    /// The team's human-readable display name.
    public let displayName: String
    /// The team's URL slug, when the backend exposes one.
    public let slug: String?

    /// Creates a team summary.
    /// - Parameters:
    ///   - id: The Stack Auth team id.
    ///   - displayName: The team's human-readable display name.
    ///   - slug: The team's URL slug, when known.
    public init(id: String, displayName: String, slug: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.slug = slug
    }
}
