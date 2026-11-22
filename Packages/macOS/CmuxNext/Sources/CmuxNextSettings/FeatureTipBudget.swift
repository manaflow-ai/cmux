public import Foundation

/// The one record every tip in the app draws on (leo-workspace design/feature-tips.md): the agent
/// chat's feature tips (`AgentPaneFeatureTipRecords`) and the sidebar's "Did you know?" card
/// (`TipChooser`). At most one tip every ``minimumDaysBetweenTips`` days across both, and whether
/// this install ran before tips did. Leo, 2026-10-30: "no this should be very very infrequent like
/// app installation level frequent and if they havent used the browser".
///
/// Client view state on this Mac (the app's defaults, as ``RecentFonts``), never cmux.json. The
/// keys keep the agent chat's names, so the date a feature tip already showed still counts.
///
/// ```swift
/// let budget = FeatureTipBudget()
/// if budget.isOpen(at: Date()) { budget.spend(at: Date()) }
/// ```
public struct FeatureTipBudget {
    /// The fewest days between two tips, whichever system shows them.
    public static let minimumDaysBetweenTips = 14
    static let lastShownKey = "agentPane.featureTips.lastShownAt"
    static let installKey = "agentPane.featureTips.install"

    private let defaults: UserDefaults

    /// The record kept in `defaults` (a test's own suite).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// When a tip last showed, from either system; nil: never.
    public var lastShownAt: Date? { defaults.object(forKey: Self.lastShownKey) as? Date }

    /// Whether a tip may show at `date`: none showed in the last ``minimumDaysBetweenTips`` days.
    public func isOpen(at date: Date) -> Bool { Self.isOpen(lastShownAt: lastShownAt, at: date) }

    /// A tip showed at `date`: no other tip for ``minimumDaysBetweenTips`` days.
    public func spend(at date: Date) { defaults.set(date, forKey: Self.lastShownKey) }

    /// Forgets the last tip (a debug reset to a fresh install).
    public func reset() { defaults.removeObject(forKey: Self.lastShownKey) }

    /// The install, as settled once on the first run of a build with tips: `existing` (it ran
    /// before) or `fresh`; nil before it is settled.
    public var install: String? { defaults.string(forKey: Self.installKey) }

    /// Settles ``install`` once: later calls keep the first answer.
    ///
    /// - Returns: True when this call settled it.
    @discardableResult
    public func settleInstall(launchedBefore: Bool) -> Bool {
        guard install == nil else { return false }
        defaults.set(launchedBefore ? "existing" : "fresh", forKey: Self.installKey)
        return true
    }

    /// Whether a tip may show at `date` when the last one showed at `lastShownAt` (pure).
    public static func isOpen(lastShownAt: Date?, at date: Date) -> Bool {
        guard let lastShownAt else { return true }
        return date.timeIntervalSince(lastShownAt) >= Double(minimumDaysBetweenTips) * 86_400
    }
}
