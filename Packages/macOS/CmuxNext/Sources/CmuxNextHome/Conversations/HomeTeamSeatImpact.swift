/// What one more member costs a team: the confirmation line of Invite to Team.
///
/// The host reads it from the team API's detail (`billing`, `viewer.permissions`) while the dialog
/// shows; until it answers the dialog says it is checking and Send waits, so the person always sees
/// the cost before the invite goes out.
public enum HomeTeamSeatImpact: Equatable, Sendable {
    /// A Team plan with a subscription: its seat count follows the members, so a join bills one
    /// more seat, prorated. `members` is the count now.
    case paidSeat(members: Int)
    /// A plan with a fixed member cap (Pro and Max personal teams): `members` of `limit` taken.
    case capped(members: Int, limit: Int)
    /// No paid plan: a join costs nothing.
    case free(members: Int)
    /// The plan could not be read; a join may add a paid seat.
    case unknown
    /// The person may not invite to this team (not an admin).
    case notAllowed

    /// Whether Send may go: false only when the team refuses this person's invites.
    public var allowsSending: Bool { self != .notAllowed }

    /// The impact for a team's billing facts.
    ///
    /// - Parameters:
    ///   - canInvite: The person's `inviteMembers` permission.
    ///   - planID: The plan (`team` for the Team plan), nil without one.
    ///   - hasSubscription: Whether the plan is paid for now.
    ///   - memberCount: The members now.
    ///   - memberLimit: A fixed member cap, nil without one.
    /// - Returns: What the confirmation line says.
    public static func of(canInvite: Bool, planID: String?, hasSubscription: Bool, memberCount: Int, memberLimit: Int?) -> Self {
        guard canInvite else { return .notAllowed }
        if let memberLimit { return .capped(members: memberCount, limit: memberLimit) }
        if hasSubscription, planID?.lowercased() == "team" { return .paidSeat(members: memberCount) }
        if hasSubscription { return .unknown }
        return .free(members: memberCount)
    }
}
