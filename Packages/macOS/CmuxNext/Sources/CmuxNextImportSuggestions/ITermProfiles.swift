public import Foundation

/// iTerm2's profiles from its preferences file (`New Bookmarks`), and each
/// profile's colors as Ghostty theme lines, the form cmux keeps a theme in.
public nonisolated struct ITermProfiles: Sendable, Equatable {
    public nonisolated struct Profile: Sendable, Equatable {
        public var name: String
        /// Whether this is iTerm2's default profile (`Default Bookmark Guid`).
        public var isDefault: Bool
        /// `palette = N=#rrggbb`, `background = #rrggbb`, ... (colors only, nothing a theme may not set).
        public var themeLines: [String]
    }

    public var profiles: [Profile]

    /// The default profile, else the first.
    public var preferred: Profile? { profiles.first(where: \.isDefault) ?? profiles.first }

    /// Nil when `data` is not a property list with profiles.
    public init?(data: Data) {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bookmarks = root["New Bookmarks"] as? [[String: Any]] else { return nil }
        let defaultGuid = root["Default Bookmark Guid"] as? String
        profiles = bookmarks.compactMap { bookmark in
            guard let name = (bookmark["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            return Profile(name: name, isDefault: defaultGuid != nil && bookmark["Guid"] as? String == defaultGuid,
                           themeLines: Self.themeLines(bookmark))
        }
    }

    /// iTerm2's color keys and the Ghostty key each becomes.
    static let colorKeys: [(iterm: String, ghostty: String)] = [
        ("Background Color", "background"), ("Foreground Color", "foreground"), ("Cursor Color", "cursor-color"),
        ("Cursor Text Color", "cursor-text"), ("Selection Color", "selection-background"),
        ("Selected Text Color", "selection-foreground"), ("Bold Color", "bold-color"),
    ]

    static func themeLines(_ bookmark: [String: Any]) -> [String] {
        // A profile with separate light and dark colors keeps the plain keys empty; the dark set stands in.
        func color(_ key: String) -> String? { hex(bookmark[key]) ?? hex(bookmark["\(key) (Dark)"]) }
        var lines = (0..<16).compactMap { index in color("Ansi \(index) Color").map { "palette = \(index)=\($0)" } }
        lines += colorKeys.compactMap { key in color(key.iterm).map { "\(key.ghostty) = \($0)" } }
        return lines
    }

    /// `{Red Component, Green Component, Blue Component}` (0...1) as `#rrggbb`.
    static func hex(_ value: Any?) -> String? {
        guard let color = value as? [String: Any] else { return nil }
        func channel(_ key: String) -> Int? {
            guard let number = (color[key] as? NSNumber)?.doubleValue, number.isFinite else { return nil }
            return Int((min(max(number, 0), 1) * 255).rounded())
        }
        guard let red = channel("Red Component"), let green = channel("Green Component"), let blue = channel("Blue Component") else { return nil }
        return String(format: "#%02x%02x%02x", red, green, blue)
    }
}
