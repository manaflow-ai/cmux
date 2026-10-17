import Foundation

/// Where an upgrade to a server-named plan goes. Personal plans start their
/// own checkout; Team Max is bought per seat on the team's subscription, so it
/// opens that team's billing page (or pricing when no team is known) and never
/// the personal Max checkout.
public enum PlanUpgradeDestination: Equatable, Sendable {
    /// The personal checkout for this plan.
    case checkout(CheckoutPlan)
    /// The web billing dashboard with this team selected.
    case teamBilling(teamID: String)
    /// The pricing page, which sells every plan.
    case pricing

    /// The team plan that sells the Max sizes and pool to every member.
    public static let teamMaxPlanID = "team_max"

    /// - Parameters:
    ///   - planID: The plan the server named (`upgradePlanId`,
    ///     `memoryUpgradePlanId`). Nil or an unknown id falls back to Max,
    ///     the plan that has always sold the locked sizes.
    ///   - teamID: The selected team, if any.
    public init(planID: String?, teamID: String?) {
        let normalized = planID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "go":
            self = .checkout(.go)
        case "pro":
            self = .checkout(.pro)
        case Self.teamMaxPlanID:
            let team = teamID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self = team.isEmpty ? .pricing : .teamBilling(teamID: team)
        default:
            self = .checkout(.max)
        }
    }

    /// Whether `planID` names Team Max.
    public static func isTeamMax(_ planID: String?) -> Bool {
        planID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == teamMaxPlanID
    }

    /// `origin/dashboard/billing?team=<teamID>`.
    public static func teamBillingURL(teamID: String, origin: URL) -> URL {
        var components = URLComponents(
            url: origin.appendingPathComponent("dashboard/billing"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "team", value: teamID)]
        return components?.url ?? origin
    }
}
