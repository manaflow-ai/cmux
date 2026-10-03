/// One cmux.json setting: its key, where the Settings window shows it, its
/// type, allowed values and default. `SettingsSchema` lists every one; the
/// Settings window, write validation and the palette's Toggle Setting read
/// it, and `SettingsSchemaTests` checks it against the cmux.json parsers, so
/// a key, default or allowed value cannot drift between them.
public nonisolated struct SettingDescriptor: Sendable, Hashable, Identifiable {
    /// Key path in cmux.json, for example `["ui", "animationSpeed"]`.
    public let path: [String]
    public let section: SettingsSection
    /// Heading of the row group inside the section.
    public let group: String
    public let title: String
    /// One line under the title; nil when the title says it all.
    public let help: String?
    public let kind: SettingKind
    /// The value an absent key means. nil when the default is derived at
    /// run time (the density's padding, the theme's color); `defaultLabel`
    /// then names it.
    public let defaultValue: JSONValue?
    public let defaultLabel: String?
    /// Extra words the Settings search matches.
    public let keywords: [String]
    /// String catalog keys of `group`, `title`, `help` and `defaultLabel`
    /// (nil for text that is not localized), so clients outside the app
    /// localize from the same catalog (`SettingsSchemaExport`).
    public let textKeys: SettingTextKeys

    /// A row whose texts come from the string catalog (`SettingsText.keyed`).
    public init(_ path: [String], section: SettingsSection, group: SettingText, title: SettingText, help: SettingText? = nil,
                kind: SettingKind, default defaultValue: JSONValue?, defaultLabel: SettingText? = nil, keywords: [String] = []) {
        self.init(path, section: section, group: group.text, title: title.text, help: help?.text, kind: kind,
                  default: defaultValue, defaultLabel: defaultLabel?.text, keywords: keywords,
                  textKeys: SettingTextKeys(group: group.key, title: title.key, help: help?.key, defaultLabel: defaultLabel?.key))
    }

    public init(_ path: [String], section: SettingsSection, group: String, title: String, help: String? = nil,
                kind: SettingKind, default defaultValue: JSONValue?, defaultLabel: String? = nil, keywords: [String] = [],
                textKeys: SettingTextKeys = SettingTextKeys()) {
        self.path = path
        self.section = section
        self.group = group
        self.title = title
        self.help = help
        self.kind = kind
        self.defaultValue = defaultValue
        self.defaultLabel = defaultLabel
        self.keywords = keywords
        self.textKeys = textKeys
    }

    /// The dotted key, as diagnostics and the CLI print it.
    public var id: String { path.joined(separator: ".") }
}

/// What a setting holds and how the Settings window edits it.
public nonisolated enum SettingKind: Sendable, Hashable {
    /// One of fixed values (a pop-up or segmented control).
    case choice([SettingChoice])
    /// A fixed value or a number (`browser.hibernation`: "off", "moderate",
    /// "aggressive" or minutes).
    case choiceOrNumber([SettingChoice], SettingNumber)
    case toggle
    case number(SettingNumber)
    /// `#RRGGBB` or `#RRGGBBAA`; absent means the theme's color.
    case color
    /// A sound: "default", "none" or a name in /System/Library/Sounds.
    case sound
    /// A web address, or empty for none.
    case url
    /// A list of host names.
    case hostList
    /// `{"start": "HH:MM", "end": "HH:MM"}`; absent means off.
    case timeRange
    /// A Ghostty theme: one theme name or `light:A,dark:B` (`AppThemeSetting`).
    case theme
    /// A font family name (`TerminalFontSetting`).
    case fontFamily
}

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
