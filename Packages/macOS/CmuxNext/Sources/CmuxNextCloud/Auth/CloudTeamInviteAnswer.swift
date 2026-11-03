/// How one team invite went (``CloudAuth/inviteOne(_:toTeam:)``), in terms a caller without the
/// auth types can switch on.
public enum CloudTeamInviteAnswer: Sendable, Hashable {
    /// cmux.com emailed the invitation.
    case sent
    /// The address belongs to someone already in the team.
    case alreadyMember
    /// cmux.com could not send the invitation email.
    case sendFailed
    /// The person may not invite to this team (not an admin, no invite permission).
    case notAllowed
    /// The session ended or cmux.com could not be reached.
    case unreachable
}
