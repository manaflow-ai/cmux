/// The string catalog keys of a descriptor's texts.
public nonisolated struct SettingTextKeys: Sendable, Hashable {
    public var group: String?
    public var title: String?
    public var help: String?
    public var defaultLabel: String?

    public init(group: String? = nil, title: String? = nil, help: String? = nil, defaultLabel: String? = nil) {
        self.group = group
        self.title = title
        self.help = help
        self.defaultLabel = defaultLabel
    }
}

/// Localized text with the string catalog key it came from.
public nonisolated struct SettingText: Sendable, Hashable {
    /// The catalog key; nil for a name that is not translated (a product name).
    public let key: String?
    /// The text in the app's language.
    public let text: String

    public init(key: String?, text: String) {
        self.key = key
        self.text = text
    }

    /// Text that is the same in every language (a product name).
    public static func verbatim(_ text: String) -> SettingText { SettingText(key: nil, text: text) }
}
