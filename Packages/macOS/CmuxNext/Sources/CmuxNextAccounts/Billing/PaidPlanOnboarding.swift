package import Foundation

/// The paid-plan welcome step (plans/cmux-next/paid-plans-DESIGN.md §2, gap 2): after a paywall
/// started an upgrade (``markPending(_:)``), the first time the app reads a paid plan for the
/// account it answers one ``Welcome``; never for the plan the app read when the upgrade started, never twice for the
/// same account and plan, and not for an upgrade started more than a day ago.
@MainActor
package struct PaidPlanOnboarding {
    /// The welcome to show for `plan`.
    package struct Welcome: Equatable, Sendable {
        package var plan: String
        package init(plan: String) { self.plan = plan }
    }

    /// How long a started upgrade waits for the plan to turn paid.
    package static let pendingFor: TimeInterval = 86_400
    private static let pendingKey = "cmux.paidPlan.pending"
    private static let pendingAtKey = "cmux.paidPlan.pendingAt"
    private static let welcomedKey = "cmux.paidPlan.welcomed"
    private static let seenKey = "cmux.paidPlan.seen"
    private static let pendingFromKey = "cmux.paidPlan.pendingFrom"

    // UserDefaults is documented thread-safe; this struct only reads and writes keys on the main actor.
    package let defaults: UserDefaults
    package var now: () -> Date

    package init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    package func markPending(_ plan: String) {
        defaults.set(plan, forKey: Self.pendingKey)
        defaults.set(now().timeIntervalSince1970, forKey: Self.pendingAtKey)
        // The plan the app last read: a plan the person already has is no upgrade.
        defaults.set(defaults.string(forKey: Self.seenKey), forKey: Self.pendingFromKey)
    }

    /// An upgrade was started within ``pendingFor``.
    package var hasPending: Bool {
        guard defaults.string(forKey: Self.pendingKey) != nil else { return false }
        return now().timeIntervalSince1970 - defaults.double(forKey: Self.pendingAtKey) < Self.pendingFor
    }

    /// The welcome for the plan the app just read (`planID`: nil or `free` is no paid plan).
    package func observe(planID: String?, account: String) -> Welcome? {
        let seen = planID?.lowercased() ?? "free"
        defaults.set(seen, forKey: Self.seenKey)
        guard let plan = planID?.lowercased(), !plan.isEmpty, plan != "free" else { return nil }
        guard hasPending, defaults.string(forKey: Self.pendingFromKey) != plan else { return nil }
        let key = "\(account)|\(plan)"
        var welcomed = defaults.stringArray(forKey: Self.welcomedKey) ?? []
        guard !welcomed.contains(key) else { return nil }
        welcomed.append(key)
        defaults.set(Array(welcomed.suffix(20)), forKey: Self.welcomedKey)
        defaults.removeObject(forKey: Self.pendingKey)
        defaults.removeObject(forKey: Self.pendingAtKey)
        defaults.removeObject(forKey: Self.pendingFromKey)
        return Welcome(plan: plan)
    }
}
