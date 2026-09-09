/// The account scope local pairing records are stamped with and filtered by:
/// the signed-in Stack user and their selected team.
///
/// Mirrors the iOS paired-Mac store scoping so a multi-team user only sees the
/// current team's computers and a sign-out hides (without deleting) pairings.
public struct HiveAccountScope: Equatable, Sendable {
    /// The signed-in Stack Auth user id, or `nil` when signed out.
    public var stackUserID: String?
    /// The selected Stack team id, or `nil` for a solo/default scope.
    public var teamID: String?

    /// Creates an account scope.
    public init(stackUserID: String?, teamID: String?) {
        self.stackUserID = stackUserID
        self.teamID = teamID
    }
}
