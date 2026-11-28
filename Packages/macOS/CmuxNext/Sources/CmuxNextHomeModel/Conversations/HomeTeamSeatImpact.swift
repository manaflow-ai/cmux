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
        let request = SeatRequest(canInvite: canInvite, planID: planID, hasSubscription: hasSubscription,
                                  memberCount: memberCount, memberLimit: memberLimit)
        let reply: SeatReply = HomeComposeRules().call("team.seatImpact", request, fallback: SeatReply(impact: .init(kind: "unknown")))
        let impact = reply.impact
        return switch impact.kind {
        case "notAllowed": .notAllowed
        case "capped": .capped(members: impact.members ?? memberCount, limit: impact.limit ?? memberLimit ?? 0)
        case "paidSeat": .paidSeat(members: impact.members ?? memberCount)
        case "free": .free(members: impact.members ?? memberCount)
        default: .unknown
        }
    }
}

/// `compose.team.seatImpact`'s request and reply.
private nonisolated struct SeatRequest: Encodable {
    var canInvite: Bool
    var planID: String?
    var hasSubscription: Bool
    var memberCount: Int
    var memberLimit: Int?
}

private nonisolated struct SeatReply: Decodable {
    struct Impact: Decodable {
        var kind: String
        var members: Int?
        var limit: Int?
    }

    var impact: Impact
}
