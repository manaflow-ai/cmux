public import Foundation

/// iTerm2's profiles from its preferences file (`New Bookmarks`), and each
/// profile's colors as Ghostty theme lines, the form cmux keeps a theme in
/// (Rust reads the property list: cmux-import-suggest's `iterm`).
public nonisolated struct ITermProfiles: Sendable, Equatable {
    public nonisolated struct Profile: Sendable, Equatable, Decodable {
        public var name: String
        /// Whether this is iTerm2's default profile (`Default Bookmark Guid`).
        public var isDefault: Bool
        /// `palette = N=#rrggbb`, `background = #rrggbb`, ... (colors only, nothing a theme may not set).
        public var themeLines: [String]
    }

    public var profiles: [Profile]

    /// The default profile, else the first.
    public private(set) var preferred: Profile?

    private struct Read: Decodable {
        var profiles: [Profile]
        var preferred: Profile?
    }

    /// Nil when `data` is not a property list with profiles.
    public init?(data: Data) {
        guard let read = ImportSuggestRules.call("iterm", ["data": data.base64EncodedString()], as: Read?.self) ?? nil else { return nil }
        profiles = read.profiles
        preferred = read.preferred
    }
}
