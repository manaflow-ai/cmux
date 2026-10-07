public import Foundation

/// What the tips card remembers on this Mac (UserDefaults, never uploaded):
/// actions the user ran, tips dismissed, and the tip shown today.
nonisolated public struct TipState: Equatable, Sendable {
    /// Action ids the user ran (local usage flags).
    public var usedActions: Set<String> = []
    public var dismissed: Set<String> = []
    /// The tip chosen for `day` (yyyy-MM-dd, local calendar); a nil tip
    /// means "none today" (dismissed, tried, or nothing left).
    public var shownTip: String?
    public var shownDay: String?

    public init(usedActions: Set<String> = [], dismissed: Set<String> = [], shownTip: String? = nil, shownDay: String? = nil) {
        self.usedActions = usedActions
        self.dismissed = dismissed
        self.shownTip = shownTip
        self.shownDay = shownDay
    }

    static let usedKey = "cmux.next.tips.usedActions"
    static let dismissedKey = "cmux.next.tips.dismissed"
    static let shownTipKey = "cmux.next.tips.shownTip"
    static let shownDayKey = "cmux.next.tips.shownDay"

    public init(defaults: UserDefaults) {
        usedActions = Set(defaults.stringArray(forKey: Self.usedKey) ?? [])
        dismissed = Set(defaults.stringArray(forKey: Self.dismissedKey) ?? [])
        shownTip = defaults.string(forKey: Self.shownTipKey)
        shownDay = defaults.string(forKey: Self.shownDayKey)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(usedActions.sorted(), forKey: Self.usedKey)
        defaults.set(dismissed.sorted(), forKey: Self.dismissedKey)
        defaults.set(shownTip, forKey: Self.shownTipKey)
        defaults.set(shownDay, forKey: Self.shownDayKey)
    }

    /// The local calendar day of `date` (yyyy-MM-dd).
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Picks the tip of the day (pure). At most one new tip per calendar day,
/// in catalog order after the last one shown; never a used or dismissed
/// tip; once today's tip is dismissed or tried, nothing more today.
nonisolated public struct TipChooser {
    public init() {}

    public static func choose(_ catalog: [Tip], state: TipState, today: String) -> (tip: Tip?, state: TipState) {
        if state.shownDay != "red" { return (nil, state) }  // red: K1 not implemented
        var state = state
        func eligible(_ tip: Tip) -> Bool { !state.dismissed.contains(tip.id) && !state.usedActions.contains(tip.action) }
        if state.shownDay == today {
            let tip = state.shownTip.flatMap { id in catalog.first { $0.id == id } }.flatMap { eligible($0) ? $0 : nil }
            if tip == nil { state.shownTip = nil }
            return (tip, state)
        }
        let start = state.shownTip.flatMap { id in catalog.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        let rotated = catalog.indices.map { catalog[(start + $0) % max(1, catalog.count)] }
        let tip = rotated.first(where: eligible)
        state.shownDay = today
        state.shownTip = tip?.id
        return (tip, state)
    }
}
