/// What the confirmation shows for one team invite (a value: the panel holds no store).
public nonisolated struct TeamInviteRequest: Sendable, Equatable {
    /// Who asked.
    public var requester: TeamInviteRequester
    /// The caller's own words (`--reason`), empty when none was given.
    public var reason: String
    /// The team the invite joins.
    public var team: TeamInviteTeam
    /// The addresses, lowercased.
    public var emails: [String]
    /// The role each invite grants.
    public var role: TeamInviteRole

    /// Creates a request.
    public init(requester: TeamInviteRequester, reason: String, team: TeamInviteTeam, emails: [String], role: TeamInviteRole) {
        self.requester = requester
        self.reason = reason
        self.team = team
        self.emails = emails
        self.role = role
    }
}
