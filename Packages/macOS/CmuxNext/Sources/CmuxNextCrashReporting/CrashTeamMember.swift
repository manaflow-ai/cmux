/// A signed-in member of the cmux team, named on their own crash and hang
/// reports (``CrashReportIdentity/member(userID:name:email:teamIDs:teamID:)``).
public nonisolated struct CrashTeamMember: Sendable, Equatable {
    /// The cmux account id.
    public let id: String
    /// The name the team sees on the report (display name, else the email's local part).
    public let name: String

    /// - Parameters:
    ///   - id: The cmux account id.
    ///   - name: The name shown on reports.
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
