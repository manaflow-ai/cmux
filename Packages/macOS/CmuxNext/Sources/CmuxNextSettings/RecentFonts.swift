public import Foundation

/// The font families written lately to any font family setting (terminal, chat code, editor,
/// Markdown code), newest first. Settings' font lists (`recent_fonts` domain) and the palette's
/// Change Font… lead with them, so switching back and forth is one step. Client view state
/// (plans/cmux-next/settings-react.md 1): kept in user defaults, never in cmux-next.json.
public struct RecentFonts {
    /// How many families are kept (the Settings page shows the same number).
    public static let limit = 6
    static let defaultsKey = "cmuxNext.recentFonts"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Newest first, at most `limit`.
    public var families: [String] {
        let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        return Array(stored.prefix(Self.limit))
    }

    /// Moves `family` to the front (trimmed; an empty name is ignored).
    public func record(_ family: String) {
        let name = family.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        defaults.set(Self.recorded(name, in: families), forKey: Self.defaultsKey)
    }

    /// A font family setting's palette values: the default (`defaultLabel`) first, a current family
    /// not installed, the installed fonts picked lately (newest first, marked recent), then every
    /// other installed family in `families`.
    public func options(current: String?, families: [String], defaultLabel: String) -> [SettingOption] {
        Self.options(current: current, families: families, recent: self.families, defaultLabel: defaultLabel)
    }

    static func options(current: String?, families: [String], recent: [String], defaultLabel: String) -> [SettingOption] {
        let installed = Set(families)
        let lately = recent.filter(installed.contains)
        var options = [SettingOption(value: nil, title: defaultLabel, isCurrent: current == nil)]
        if let current, !installed.contains(current) {
            options.append(SettingOption(value: .string(current), title: current, isCurrent: true))
        }
        options += (lately + families.filter { !lately.contains($0) }).map {
            SettingOption(value: .string($0), title: $0, isCurrent: current == $0, isRecent: lately.contains($0))
        }
        return options
    }

    static func recorded(_ family: String, in list: [String]) -> [String] {
        Array(([family] + list.filter { $0 != family }).prefix(limit))
    }
}
