/// What a team's plan says about one more member (``CloudAuth/seatFacts(teamID:)``): the facts the
/// Invite to Team dialog turns into its cost line.
public struct CloudTeamSeatFacts: Sendable, Hashable {
    /// Whether the signed-in person may invite to the team.
    public var canInvite: Bool
    /// The plan (`team` for the Team plan); nil without one.
    public var planID: String?
    /// Whether the plan is paid for now.
    public var hasSubscription: Bool
    /// The members now.
    public var memberCount: Int
    /// A fixed member cap; nil without one.
    public var memberLimit: Int?

    /// - Parameters:
    ///   - canInvite: The person's invite permission.
    ///   - planID: The plan id, nil without one.
    ///   - hasSubscription: Whether the plan is paid for now.
    ///   - memberCount: The members now.
    ///   - memberLimit: A fixed member cap, nil without one.
    public init(canInvite: Bool, planID: String?, hasSubscription: Bool, memberCount: Int, memberLimit: Int?) {
        self.canInvite = canInvite
        self.planID = planID
        self.hasSubscription = hasSubscription
        self.memberCount = memberCount
        self.memberLimit = memberLimit
    }
}
