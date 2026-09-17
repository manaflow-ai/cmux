import Foundation

/// Display-only view of a cmux team the current user belongs to.
///
/// Surface for the package's ``AccountSection`` to render the team
/// picker. The host derives this from its own team type.
public struct AccountTeamSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let slug: String?

    public init(id: String, displayName: String, slug: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.slug = slug
    }
}
