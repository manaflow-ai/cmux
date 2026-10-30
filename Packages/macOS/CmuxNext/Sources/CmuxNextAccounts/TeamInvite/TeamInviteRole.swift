/// The role a team invite grants on accept (`POST /api/teams/{id}/invitations` `role`).
public nonisolated enum TeamInviteRole: String, Sendable, Equatable, CaseIterable {
    /// A regular member (the default).
    case member
    /// A team admin: may invite, remove and manage billing.
    case admin
}
