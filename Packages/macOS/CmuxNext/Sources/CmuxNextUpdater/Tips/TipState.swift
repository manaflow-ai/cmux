public import Foundation

/// What the tips card remembers on this Mac (UserDefaults, never uploaded;
/// kept across restarts and updates): actions the user ran, tips dismissed,
/// tips the person saw on screen (each shows once, ever), the tip chosen
/// today, and the end of a timed mute ("Mute Tips for 1 Day/Week").
nonisolated public struct TipState: Equatable, Sendable {
    /// Action ids the user ran (local usage flags).
    public var usedActions: Set<String> = []
    public var dismissed: Set<String> = []
    /// Tip ids whose card was on screen: never picked again.
    public var seen: Set<String> = []
    /// The tip chosen for `day` (yyyy-MM-dd, local calendar); a nil tip
    /// means "none today" (dismissed, tried, or nothing left).
    public var shownTip: String?
    public var shownDay: String?
    /// No tip shows before this moment (a timed mute); nil: not muted.
    /// Read only when a tip would show, never on a timer.
    public var mutedUntil: Date?

    public init(usedActions: Set<String> = [], dismissed: Set<String> = [], shownTip: String? = nil, shownDay: String? = nil,
                mutedUntil: Date? = nil) {
        self.usedActions = usedActions
        self.dismissed = dismissed
        self.shownTip = shownTip
        self.shownDay = shownDay
        self.mutedUntil = mutedUntil
    }

    static let usedKey = "cmux.next.tips.usedActions"
    static let dismissedKey = "cmux.next.tips.dismissed"
    static let shownTipKey = "cmux.next.tips.shownTip"
    static let shownDayKey = "cmux.next.tips.shownDay"
    static let mutedUntilKey = "cmux.next.tips.mutedUntil"
    static let seenKey = "cmux.next.tips.seen"

    public init(defaults: UserDefaults) {
        usedActions = Set(defaults.stringArray(forKey: Self.usedKey) ?? [])
        dismissed = Set(defaults.stringArray(forKey: Self.dismissedKey) ?? [])
        shownTip = defaults.string(forKey: Self.shownTipKey)
        shownDay = defaults.string(forKey: Self.shownDayKey)
        mutedUntil = defaults.object(forKey: Self.mutedUntilKey) as? Date
        if let seen = defaults.stringArray(forKey: Self.seenKey) {
            self.seen = Set(seen)
        } else if let shown = shownTip, let index = TipCatalog.all.firstIndex(where: { $0.id == shown }) {
            // State from before seen tips were recorded: the rotation went in catalog order, so
            // every tip up to the last one shown was seen.
            self.seen = Set(TipCatalog.all[...index].map(\.id))
        }
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(usedActions.sorted(), forKey: Self.usedKey)
        defaults.set(dismissed.sorted(), forKey: Self.dismissedKey)
        defaults.set(shownTip, forKey: Self.shownTipKey)
        defaults.set(shownDay, forKey: Self.shownDayKey)
        defaults.set(mutedUntil, forKey: Self.mutedUntilKey)
        defaults.set(seen.sorted(), forKey: Self.seenKey)
    }

    /// The local calendar day of `date` (yyyy-MM-dd).
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Picks the tip of the day (pure). At most one new tip per calendar day,
/// in catalog order after the last one shown; never a used, dismissed or
/// seen tip (each tip shows once, ever; a tip a later release adds is
/// unseen, so it shows once too; with every tip seen, none). Today's tip
/// stays while it is still on the card (`showing`) even though it is seen;
/// once it is dismissed, tried, or gone (a restart), nothing more today.
nonisolated public struct TipChooser {
    public init() {}

    public static func choose(_ catalog: [Tip], state: TipState, today: String, showing: String? = nil) -> (tip: Tip?, state: TipState) {
        var state = state
        func open(_ tip: Tip) -> Bool { !state.dismissed.contains(tip.id) && !state.usedActions.contains(tip.action) }
        func eligible(_ tip: Tip) -> Bool { open(tip) && !state.seen.contains(tip.id) }
        if state.shownDay == today {
            let tip = state.shownTip.flatMap { id in catalog.first { $0.id == id } }
                .flatMap { eligible($0) || ($0.id == showing && open($0)) ? $0 : nil }
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
