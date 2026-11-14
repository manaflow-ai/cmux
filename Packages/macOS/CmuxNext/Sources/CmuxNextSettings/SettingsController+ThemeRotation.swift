public import Foundation

extension SettingsController {
    /// The UserDefaults key of the day of the last Rotate Starred Themes turn: bookkeeping, not a setting.
    static let themeRotationDayKey = "cmux.favoriteThemes.lastRotationDay"

    /// `appearance.rotateFavoriteThemes` at launch: writes the next starred theme to `appearance.theme`
    /// (``ThemeFavoritesSetting/rotated(_:today:lastDay:)`` picks it), so the terminals and the
    /// pickers follow it like any other theme change. `root` is cmux.json as launch loaded it.
    public func rotateFavoriteThemeAtLaunch(root: JSONValue, defaults: UserDefaults = .standard,
                                            now: Date = Date(), calendar: Calendar = .current) {
        let today = ThemeFavoritesSetting.day(now, calendar: calendar)
        let lastDay = defaults.string(forKey: Self.themeRotationDayKey)
        guard let next = ThemeFavoritesSetting().rotated(root, today: today, lastDay: lastDay) else { return }
        defaults.set(today, forKey: Self.themeRotationDayKey)
        Task { try? await setSetting(at: AppThemeSetting.configPath, to: .string(next), by: .user) }
    }
}
