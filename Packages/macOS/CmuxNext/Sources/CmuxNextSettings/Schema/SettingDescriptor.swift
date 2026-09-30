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

    public init(_ path: [String], section: SettingsSection, group: String, title: String, help: String? = nil,
                kind: SettingKind, default defaultValue: JSONValue?, defaultLabel: String? = nil, keywords: [String] = []) {
        self.path = path
        self.section = section
        self.group = group
        self.title = title
        self.help = help
        self.kind = kind
        self.defaultValue = defaultValue
        self.defaultLabel = defaultLabel
        self.keywords = keywords
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
}

public nonisolated struct SettingChoice: Sendable, Hashable {
    public let value: String
    public let title: String

    public init(_ value: String, _ title: String) {
        self.value = value
        self.title = title
    }
}

public nonisolated struct SettingNumber: Sendable, Hashable {
    public enum Unit: Sendable, Hashable { case points, seconds, minutes, count }

    public let range: ClosedRange<Double>
    public let step: Double
    public let unit: Unit
    /// Where the control sits while the key is absent and the default is
    /// derived (`defaultValue` nil).
    public let placeholder: Double

    public init(_ range: ClosedRange<Double>, step: Double, unit: Unit, placeholder: Double? = nil) {
        self.range = range
        self.step = step
        self.unit = unit
        self.placeholder = placeholder ?? range.lowerBound
    }
}
