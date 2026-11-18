import CmuxNextDesign
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
        var seen = Set<String>()
        return (root.value(at: Self.favoritesPath)?.arrayValue ?? Self.favoritesDefault.map { .string($0) }).compactMap { item in
            guard let name = item.stringValue, let spec = ThemeSpec(name), spec.light == name, spec.dark == name,
                  seen.insert(name).inserted else { return nil }
            return name
        }
    }

    /// A missing or unknown value is the default (off).
    public func rotation(_ root: JSONValue) -> ThemeRotation {
        root.value(at: Self.rotationPath)?.stringValue.flatMap(ThemeRotation.init(rawValue:)) ?? Self.rotationDefault
    }

    /// The starred theme after `current`, wrapping; the first when `current` is none of them. Nil
    /// with fewer than two, where there is nothing to turn to.
    public static func next(after current: String?, in favorites: [String]) -> String? {
        guard favorites.count >= 2 else { return nil }
        guard let current, let index = favorites.firstIndex(of: current) else { return favorites[0] }
        return favorites[(index + 1) % favorites.count]
    }

    /// The theme launch writes to `appearance.theme`, or nil to leave it. `today` and `lastDay` are
    /// local days (`day(_:calendar:)`); Daily turns only when they differ. A light/dark pair
    /// (Match System Appearance) is left alone, even one naming the same theme twice or one side
    /// only: one starred theme would replace both sides and turn Match System Appearance off.
    public func rotated(_ root: JSONValue, today: String, lastDay: String?) -> String? {
        switch rotation(root) {
        case .off: return nil
        case .daily where lastDay == today: return nil
        case .launch, .daily: break
        }
        let current = root.value(at: AppThemeSetting.configPath)?.stringValue
        if let current, ThemeSpec(current)?.isPair ?? false { return nil }
        return Self.next(after: current, in: favorites(root))
    }

    /// The local day of `date`, such as "2026-10-20".
    public static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
