public import Foundation

/// The analytics state that must survive relaunch: install cohort, reached
/// milestones, per-day feature dedupe, the last version, the last upgrade
/// click and the last known plan. Stored in an injected `UserDefaults` under
/// `cmux.analytics.*`.
///
/// Confined to the ``ProductAnalytics`` pipeline actor; never read elsewhere.
// `UserDefaults` is documented thread-safe; the ledger is only touched from
// the pipeline actor, so `@unchecked Sendable` adds no shared mutation.
public struct ProductAnalyticsLedger: @unchecked Sendable {
    private let defaults: UserDefaults

    /// - Parameter defaults: The store. The app passes `.standard`; tests pass a suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Key {
        static let installFirstSeenAt = "cmux.analytics.installFirstSeenAt"
        static let installIsNew = "cmux.analytics.installIsNew"
        static let milestones = "cmux.analytics.milestones"
        static let featureDays = "cmux.analytics.featureDays"
        static let lastVersion = "cmux.analytics.lastVersion"
        static let lastUpgradeSource = "cmux.analytics.lastUpgradeSource"
        static let lastUpgradeAt = "cmux.analytics.lastUpgradeAt"
        static let lastUpgradeAccount = "cmux.analytics.lastUpgradeAccount"
        static let lastPlanAccount = "cmux.analytics.lastPlanAccount"
        static let lastPlanPaid = "cmux.analytics.lastPlanPaid"
    }

    /// When this install was first seen by the catalog, recording it on the
    /// first call. Returns whether that first call happened now.
    mutating func registerInstall(now: Date, isPreexisting: Bool) -> (firstSeenAt: Date, isNewInstall: Bool, isFirstRun: Bool) {
        if let date = defaults.object(forKey: Key.installFirstSeenAt) as? Date {
            return (date, defaults.bool(forKey: Key.installIsNew), false)
        }
        defaults.set(now, forKey: Key.installFirstSeenAt)
        defaults.set(!isPreexisting, forKey: Key.installIsNew)
        return (now, !isPreexisting, true)
    }

    var installFirstSeenAt: Date? { defaults.object(forKey: Key.installFirstSeenAt) as? Date }
    var installIsNew: Bool { defaults.bool(forKey: Key.installIsNew) }

    /// Marks `milestone` reached; true only the first time.
    func claimMilestone(_ milestone: ActivationMilestone) -> Bool {
        var reached = Set(defaults.stringArray(forKey: Key.milestones) ?? [])
        guard reached.insert(milestone.rawValue).inserted else { return false }
        defaults.set(reached.sorted(), forKey: Key.milestones)
        return true
    }

    /// Marks `feature` used on `day`; true only for the first use that day.
    func claimFeatureDay(_ feature: ProductFeature, day: String) -> Bool {
        var days = defaults.dictionary(forKey: Key.featureDays) as? [String: String] ?? [:]
        guard days[feature.rawValue] != day else { return false }
        days[feature.rawValue] = day
        defaults.set(days, forKey: Key.featureDays)
        return true
    }

    /// Records `version` and returns the previous launch's version. Writes
    /// only on a change: every defaults write notifies app-wide observers.
    func swapLastVersion(_ version: String) -> String? {
        let previous = defaults.string(forKey: Key.lastVersion)
        if previous != version { defaults.set(version, forKey: Key.lastVersion) }
        return previous
    }

    /// Records an upgrade click. `account` is the signed-in account, or nil
    /// when signed out (the click may then lead to any account's checkout).
    func recordUpgradeClick(source: String, account: String?, at date: Date) {
        defaults.set(source, forKey: Key.lastUpgradeSource)
        defaults.set(date, forKey: Key.lastUpgradeAt)
        defaults.set(account, forKey: Key.lastUpgradeAccount)
    }

    /// The last unattributed click that may apply to `account`.
    func upgradeClick(for account: String) -> (source: String, at: Date)? {
        guard let source = defaults.string(forKey: Key.lastUpgradeSource),
              let date = defaults.object(forKey: Key.lastUpgradeAt) as? Date else { return nil }
        if let clickAccount = defaults.string(forKey: Key.lastUpgradeAccount), clickAccount != account { return nil }
        return (source, date)
    }

    /// Forgets the click once a plan activation used it.
    func clearUpgradeClick() {
        defaults.removeObject(forKey: Key.lastUpgradeSource)
        defaults.removeObject(forKey: Key.lastUpgradeAt)
        defaults.removeObject(forKey: Key.lastUpgradeAccount)
    }

    /// Records the plan for `account` and returns what was known for that
    /// account before, or nil when it was a different or no account. Writes
    /// only on a change.
    func swapPlan(account: String, isPaid: Bool) -> Bool? {
        let previousAccount = defaults.string(forKey: Key.lastPlanAccount)
        let previous = previousAccount == account ? defaults.object(forKey: Key.lastPlanPaid) as? Bool : nil
        if previousAccount != account { defaults.set(account, forKey: Key.lastPlanAccount) }
        if previous != isPaid { defaults.set(isPaid, forKey: Key.lastPlanPaid) }
        return previous
    }
}
