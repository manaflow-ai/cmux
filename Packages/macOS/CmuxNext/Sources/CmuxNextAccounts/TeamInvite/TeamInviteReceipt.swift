/// What a sent team invite answers its caller: the team and each invitation,
/// pending until the person invited accepts.
public nonisolated struct TeamInviteReceipt: Sendable, Equatable {
    /// The team the invites join.
    public var team: TeamInviteTeam
    /// What cmux.com sent and refused.
    public var outcome: TeamInviteOutcome
    /// The done note ("Invite sent to leo@cmux.com for “cmux”.").
    public var message: String

    /// Creates a receipt.
    public init(team: TeamInviteTeam, outcome: TeamInviteOutcome, message: String) {
        self.team = team
        self.outcome = outcome
        self.message = message
    }
}
