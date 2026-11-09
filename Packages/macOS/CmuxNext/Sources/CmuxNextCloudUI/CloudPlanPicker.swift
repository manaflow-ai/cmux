public import Foundation

/// The plan picker a Cloud workspace create shows when the account's plan has no Cloud machines (the free-plan gate
/// and the server's `cloud.plan.required`, cmux#38299): Monthly or Annual, then Pro, Max or Team, each with its price,
/// included usage, what is due today and its machine limits. Only Cloud is paid: local workspaces stay free, and the
/// picker can offer Run on This Mac instead.
///
/// Prices follow web billing (`web/services/billing/plans.ts`: Pro $50 or $480 a year, Max $200 or $1,920 a year,
/// Team $60 a seat, monthly only); included usage follows `chiefPricing.ts`; machine limits follow
/// `web/services/vms/machineSpec.ts` and `images/sizes.ts`.
public nonisolated struct CloudPlanPicker: Equatable, Sendable {
    /// How the plan is billed. New checkouts default to monthly.
    public enum Interval: String, Equatable, Sendable, CaseIterable { case month, year }

    /// A plan the picker sells; its raw value is web billing's plan id (`POST /api/billing/checkout`).
    public enum PlanID: String, Equatable, Sendable, CaseIterable { case pro, max, team }

    /// One card.
    public struct Plan: Equatable, Sendable {
        public var id: PlanID
        /// USD a month, billed monthly.
        public var monthly: Int
        /// USD a year, billed yearly; nil when the plan is sold monthly only (Team).
        public var yearly: Int?
        /// Priced per seat (Team).
        public var perSeat: Bool
        /// USD of usage the plan includes each month (per seat for Team).
        public var includedUsage: Int
        /// Largest machine: vCPUs and GB of memory.
        public var machineCPU: Int
        public var machineMemoryGB: Int
        /// vCPUs and GB of memory all running machines share (per seat for Team).
        public var poolCPU: Int
        public var poolMemoryGB: Int
        /// Running machines at a time (per seat for Team).
        public var machines: Int
        /// GB of disk each machine may grow to.
        public var storageGB: Int
    }

    /// Pro, Max, Team: the order the cards show.
    public static let plans: [Plan] = [
        Plan(id: .pro, monthly: 50, yearly: 480, perSeat: false, includedUsage: 25,
             machineCPU: 8, machineMemoryGB: 16, poolCPU: 20, poolMemoryGB: 40, machines: 5, storageGB: 256),
        Plan(id: .max, monthly: 200, yearly: 1_920, perSeat: false, includedUsage: 100,
             machineCPU: 32, machineMemoryGB: 64, poolCPU: 80, poolMemoryGB: 160, machines: 5, storageGB: 256),
        Plan(id: .team, monthly: 60, yearly: nil, perSeat: true, includedUsage: 25,
             machineCPU: 8, machineMemoryGB: 16, poolCPU: 20, poolMemoryGB: 40, machines: 5, storageGB: 256),
    ]

    /// What the person picked.
    public enum Choice: Equatable, Sendable {
        /// Check out `plan`, billed every `interval` (always `.month` for a plan sold monthly only).
        case plan(PlanID, Interval)
        /// Run the work on this Mac instead: local use is free.
        case runHere
    }

    /// The billing the toggle shows; Monthly first.
    public var interval: Interval
    /// The plan the refusal named, drawn as recommended (Pro unless the server asked for Max).
    public var recommended: PlanID
    /// Offers Run on This Mac (a create that can run here instead).
    public var offersRunHere: Bool

    /// The cards shown: every plan, or only Max when Max is what the refusal asks for (the account already has a
    /// paid plan, so Pro and Team would sell it what it has).
    public var shownPlans: [Plan] { recommended == .max ? Self.plans.filter { $0.id == .max } : Self.plans }

    public init(interval: Interval = .month, recommended: PlanID = .pro, offersRunHere: Bool = false) {
        self.interval = interval
        self.recommended = recommended
        self.offersRunHere = offersRunHere
    }

    /// The plan a refusal's `plan` names: Max for `max`, Pro otherwise.
    public static func recommended(for plan: String?) -> PlanID { plan == PlanID.max.rawValue ? .max : .pro }

    /// The interval `plan` is billed at under the toggle: a plan sold monthly only stays monthly.
    public func billing(_ plan: Plan) -> Interval { plan.yearly == nil ? .month : interval }

    /// USD a month the card shows (the yearly price over twelve months on Annual).
    public func monthlyPrice(_ plan: Plan) -> Int {
        guard billing(plan) == .year, let yearly = plan.yearly else { return plan.monthly }
        return yearly / 12
    }

    /// USD charged today: a month, or the whole year on Annual (one seat for Team).
    public func dueToday(_ plan: Plan) -> Int {
        guard billing(plan) == .year, let yearly = plan.yearly else { return plan.monthly }
        return yearly
    }

    /// Whole percent the yearly price saves over twelve monthly payments; nil for a plan sold monthly only.
    public static func annualSaving(_ plan: Plan) -> Int? {
        guard let yearly = plan.yearly else { return nil }
        return Int((Double(plan.monthly * 12 - yearly) / Double(plan.monthly * 12) * 100).rounded())
    }

    /// The best saving any plan has on Annual (the toggle's label).
    public static var bestAnnualSaving: Int { plans.compactMap(annualSaving).max() ?? 0 }

    /// The choice for the card of `plan` under the toggle.
    public func choice(_ plan: Plan) -> Choice { .plan(plan.id, billing(plan)) }

    /// `usd` as a whole-dollar price in the person's locale (`$50`).
    public static func price(_ usd: Int, locale: Locale = .current) -> String {
        usd.formatted(.currency(code: "USD").locale(locale).precision(.fractionLength(0)))
    }
}
