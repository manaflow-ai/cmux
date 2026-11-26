import Foundation

/// A cmux subscription tier, ordered so each tier includes every feature of
/// the tiers below it.
///
/// Gate features on the ordering (``includesPro``, ``includesMax``) rather
/// than on a plan string, so Max and any later higher tier keep everything
/// Pro has.
public enum CmuxPlanTier: Int, Sendable, Comparable, CaseIterable {
    /// No paid plan.
    case free
    /// The entry Cloud plan: a small machine allowance, no Pro features.
    case go
    /// Pro, and the plans that grant the Pro feature set (Team, Founder's Edition).
    case pro
    /// Max: everything in Pro plus the larger machine sizes and pool.
    case max

    /// Maps a plan ID from the Cloud service, or `nil` for an unknown ID.
    ///
    /// - Parameter planID: A plan ID such as `free`, `go`, `pro`, `max`,
    ///   `team`, or `founders`. Case and surrounding whitespace are ignored.
    public init?(planID: String?) {
        switch planID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "free": self = .free
        case "go": self = .go
        case "pro", "team", "founders": self = .pro
        case "max": self = .max
        default: return nil
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whether the tier includes Cloud machines.
    public var includesCloud: Bool { self >= .go }

    /// Whether the tier includes every Pro feature.
    public var includesPro: Bool { self >= .pro }

    /// Whether the tier includes every Max feature.
    public var includesMax: Bool { self >= .max }

    /// The tier an upgrade from this one should offer, or `nil` at the top.
    public var nextUpgrade: CmuxPlanTier? {
        switch self {
        case .free, .go: .pro
        case .pro: .max
        case .max: nil
        }
    }

    /// The account's effective tier from a `/api/billing/plan` response: the
    /// higher of the personal plan and the active team's plan.
    ///
    /// - Parameters:
    ///   - subscriptionPlanID: The exact personal plan (`free`, `go`, `pro`,
    ///     or `max`), or `nil` from servers that predate it.
    ///   - planID: The legacy personal plan family, `free` or `pro`. A Max
    ///     or Go subscriber is reported as `pro` here.
    ///   - teamPlanID: The active team's plan, if any.
    ///   - isPro: The legacy paid flag, used only when no plan ID is known.
    public static func resolved(
        subscriptionPlanID: String?,
        planID: String?,
        teamPlanID: String?,
        isPro: Bool
    ) -> CmuxPlanTier {
        let personal = CmuxPlanTier(planID: subscriptionPlanID)
            ?? CmuxPlanTier(planID: planID)
            ?? (isPro ? .pro : .free)
        let team = CmuxPlanTier(planID: teamPlanID) ?? .free
        return Swift.max(personal, team)
    }

    /// The tier an upgrade entrypoint should offer, or `nil` to hide it.
    ///
    /// - Parameters:
    ///   - isSignedIn: Whether an account is signed in.
    ///   - knownTier: The signed-in account's tier, or `nil` while it is
    ///     loading or after its fetch failed. An unknown tier is never read
    ///     as Free, so it offers nothing.
    public static func upgradeOffer(isSignedIn: Bool, knownTier: CmuxPlanTier?) -> CmuxPlanTier? {
        guard isSignedIn else { return .pro }
        return knownTier?.nextUpgrade
    }
}
