/// The cmux.com calls a team invite needs, as the signed-in person. The App
/// conforms its signed-in web client; tests pass a fake.
public nonisolated protocol TeamInviteBackend: Sendable {
    /// The teams the person belongs to.
    ///
    /// - Throws: ``TeamInviteBackendError`` when cmux.com refuses or is unreachable.
    func teams() async throws -> [TeamInviteTeam]

    /// Sends one email invite per address (`POST /api/teams/{teamID}/invitations`).
    ///
    /// - Parameters:
    ///   - teamID: The team to invite into.
    ///   - emails: The addresses, already validated and lowercased.
    ///   - role: The role each invite grants.
    /// - Returns: What cmux.com sent and refused.
    /// - Throws: ``TeamInviteBackendError`` when cmux.com refuses (`team_admin_required`, `rate_limited`, …).
    func invite(teamID: String, emails: [String], role: TeamInviteRole) async throws -> TeamInviteOutcome
}
