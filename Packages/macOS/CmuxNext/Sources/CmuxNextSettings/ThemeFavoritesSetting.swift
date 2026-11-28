public import Foundation

/// `appearance.favoriteThemes` and `appearance.rotateFavoriteThemes` in cmux.json: the themes starred
/// in a theme picker, which it lists first, and whether launch turns `appearance.theme` to the next
/// starred theme (Leo, 2026-10-20: "you should also be able to star themes and pick from them and
/// maybe even be able to have them rotate"). The pick is pure; the app's launch writes it.
public nonisolated struct ThemeFavoritesSetting: Sendable {
    public init() {}

    /// The starred theme names in the order they were starred: one theme name each, as the pickers
    /// write it (no pair, no padding), without repeats.
    public func favorites(_ root: JSONValue) -> [String] {
        (SettingsRust.answer("theme.favorites", ["root": root])["favorites"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    /// The starred theme after `current`, wrapping; the first when `current` is none of them. Nil
    /// with fewer than two, where there is nothing to turn to.
    public static func next(after current: String?, in favorites: [String]) -> String? {
        SettingsRust.answer("theme.favorite_next", [
            "current": current.map(JSONValue.string) ?? .null, "favorites": .array(favorites.map(JSONValue.string)),
        ])["next"]?.stringValue
    }

    /// The theme launch writes to `appearance.theme`, or nil to leave it. `today` and `lastDay` are
    /// local days (`day(_:calendar:)`); Daily turns only when they differ. A light/dark pair
    /// (Match System Appearance) is left alone, even one naming the same theme twice or one side
    /// only: one starred theme would replace both sides and turn Match System Appearance off.
    public func rotated(_ root: JSONValue, today: String, lastDay: String?) -> String? {
        SettingsRust.answer("theme.favorite_rotated", [
            "root": root, "today": .string(today), "last_day": lastDay.map(JSONValue.string) ?? .null,
        ])["next"]?.stringValue
    }

    /// The local day of `date`, such as "2026-10-20".
    public static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
