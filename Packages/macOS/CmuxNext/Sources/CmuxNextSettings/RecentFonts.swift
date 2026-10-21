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

    static func recorded(_ family: String, in list: [String]) -> [String] {
        Array(([family] + list.filter { $0 != family }).prefix(limit))
    }
}
