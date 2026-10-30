/// One cmux team the signed-in person belongs to, as cmux.com lists it
/// (`GET /api/subrouter/teams`).
public nonisolated struct TeamInviteTeam: Sendable, Equatable {
    /// The Stack team id (`team_…` or a UUID).
    public var id: String
    /// The team's display name ("cmux").
    public var name: String
    /// Whether this is the person's own personal team (never a default target).
    public var personal: Bool

    /// Creates a team row.
    ///
    /// - Parameters:
    ///   - id: The Stack team id.
    ///   - name: The display name.
    ///   - personal: Whether it is the person's personal team.
    public init(id: String, name: String, personal: Bool = false) {
        self.id = id
        self.name = name
        self.personal = personal
    }
}
