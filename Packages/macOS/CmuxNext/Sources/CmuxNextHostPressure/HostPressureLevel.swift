/// How hard the host is pressed, as the app shows it: nothing, a calm
/// titlebar indicator, or a dismissible banner.
public enum HostPressureLevel: Int, Comparable, Sendable, CaseIterable {
    case normal, warning, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Turns budget verdicts into a level that does not flicker (pure; the
/// monitor feeds it on its timer and on each memory pressure event).
///
/// The levels sit on the shared budget, never on caps of their own:
/// - warning: one part of the budget is over (load at the limit, memory
///   pressure warn, swap growing at the budget's rate), or the load reached
///   `loadWarnFraction` of its limit, before acpmux would warn;
/// - critical: memory pressure is critical, or two parts are over at once
///   (a busy CPU alone is a busy Mac, not a freeze; Leo: "just limit it nicer").
///
/// A level rises on the first verdict that reaches it and falls only after
/// `calmSamples` verdicts in a row below it; a load warning also holds until
/// the load is `loadReleaseFraction` under where it started.
public struct HostPressureTracker: Sendable {
    /// The warning's load line, as a share of the budget's load limit.
    public static let loadWarnFraction = 0.75
    /// The deadband under the load line that keeps a warning up.
    public static let loadReleaseFraction = 0.10

    public private(set) var level: HostPressureLevel = .normal
    /// The last verdict fed.
    public private(set) var verdict: HostBudgetVerdict?
    public let calmSamples: Int
    private var calmStreak = 0

    public init(calmSamples: Int = 2) {
        self.calmSamples = max(1, calmSamples)
    }

    /// The level `verdict` alone calls for while the tracker holds `current`.
    public static func level(for verdict: HostBudgetVerdict, holding current: HostPressureLevel) -> HostPressureLevel {
        if verdict.pressure == .critical || verdict.over.count >= 2 { return .critical }
        if !verdict.over.isEmpty { return .warning }
        let line = loadWarnFraction - (current > .normal ? loadReleaseFraction : 0)
        return (verdict.load1 ?? 0) >= verdict.loadLimit * line ? .warning : .normal
    }

    /// Feeds one verdict; returns the new level when it changed.
    public mutating func feed(_ verdict: HostBudgetVerdict) -> HostPressureLevel? {
        self.verdict = verdict
        let wanted = Self.level(for: verdict, holding: level)
        guard wanted < level else {
            calmStreak = 0
            guard wanted != level else { return nil }
            level = wanted
            return wanted
        }
        calmStreak += 1
        guard calmStreak >= calmSamples else { return nil }
        calmStreak = 0
        level = wanted
        return wanted
    }
}
