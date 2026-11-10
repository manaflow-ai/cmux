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
    /// The team's plan id (`client_read_only_metadata.cmuxPlan`, which only the server and web
    /// billing write), nil when the team has none or it was not read.
    public let plan: String?

    /// Creates a team summary.
    /// - Parameters:
    ///   - id: The Stack Auth team id.
    ///   - displayName: The team's human-readable display name.
    ///   - slug: The team's URL slug, when known.
    ///   - plan: The team's plan id, when known.
    public init(id: String, displayName: String, slug: String? = nil, plan: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.slug = slug
        self.plan = plan
    }

    /// The plan id a team's read-only metadata names (`cmuxPlan`): a non-empty string of at most 64
    /// characters, else nil (the backend's `readOnlyPlan`).
    public static func plan(fromClientReadOnlyMetadata metadata: [String: Any]) -> String? {
        guard let plan = metadata["cmuxPlan"] as? String, !plan.isEmpty, plan.count <= 64 else { return nil }
        return plan
    }
}
