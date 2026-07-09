public import Foundation

/// A pure, `Sendable` description of one settings-backed command-palette toggle.
///
/// The descriptor closes over the read/write/availability of a single boolean
/// setting via injected `@Sendable` closures, so it references no app types and
/// holds no live state. Its display text is computed from injected, app-resolved
/// localized formats (``CommandPaletteSettingToggleStrings``); the title/section
/// text comes from the descriptor's own `@Sendable` closures. Localization stays
/// app-side because `String(localized:)` would otherwise bind to this package's
/// bundle and drop non-English translations.
public struct CommandPaletteSettingToggleDescriptor: Sendable {
    /// Stable palette command identifier.
    public let commandId: String
    /// The settings key this toggle binds to (used for search keywords).
    public let settingsKey: String
    /// Resolves the setting's human-readable title.
    public let title: @Sendable () -> String
    /// Resolves the title of the settings section this toggle belongs to.
    public let sectionTitle: @Sendable () -> String
    /// Additional search keywords for this command.
    public let keywords: [String]
    /// Reads whether the setting is currently on.
    public let isOn: @Sendable (UserDefaults) -> Bool
    /// Writes the setting's new value and runs any side effects.
    public let setOn: @Sendable (Bool, UserDefaults, NotificationCenter) -> Void
    /// Reports whether this toggle is currently available (offered/togglable).
    public let isAvailable: @Sendable (UserDefaults) -> Bool

    /// Creates a descriptor backed by a `UserDefaults` key with a default value.
    ///
    /// - Parameters:
    ///   - defaultValue: Value returned when the key is absent.
    ///   - defaultsKey: The `UserDefaults` key the toggle reads and writes.
    ///   - didSet: Side effect run after each write (e.g. posting a change
    ///     notification).
    public init(
        commandId: String,
        settingsKey: String,
        title: @escaping @Sendable () -> String,
        sectionTitle: @escaping @Sendable () -> String,
        keywords: [String],
        defaultValue: Bool,
        defaultsKey: String,
        isAvailable: @escaping @Sendable (UserDefaults) -> Bool = { _ in true },
        didSet: @escaping @Sendable (Bool, UserDefaults, NotificationCenter) -> Void = { _, _, _ in }
    ) {
        self.commandId = commandId
        self.settingsKey = settingsKey
        self.title = title
        self.sectionTitle = sectionTitle
        self.keywords = keywords
        self.isOn = { defaults in
            if defaults.object(forKey: defaultsKey) == nil {
                return defaultValue
            }
            return defaults.bool(forKey: defaultsKey)
        }
        self.setOn = { newValue, defaults, notificationCenter in
            defaults.set(newValue, forKey: defaultsKey)
            didSet(newValue, defaults, notificationCenter)
        }
        self.isAvailable = isAvailable
    }

    /// Creates a descriptor with fully custom read/write closures.
    public init(
        commandId: String,
        settingsKey: String,
        title: @escaping @Sendable () -> String,
        sectionTitle: @escaping @Sendable () -> String,
        keywords: [String],
        isOn: @escaping @Sendable (UserDefaults) -> Bool,
        setOn: @escaping @Sendable (Bool, UserDefaults, NotificationCenter) -> Void,
        isAvailable: @escaping @Sendable (UserDefaults) -> Bool = { _ in true }
    ) {
        self.commandId = commandId
        self.settingsKey = settingsKey
        self.title = title
        self.sectionTitle = sectionTitle
        self.keywords = keywords
        self.isOn = isOn
        self.setOn = setOn
        self.isAvailable = isAvailable
    }

    /// The "Enable %@" / "Disable %@" command title for the current state.
    ///
    /// - Parameter strings: App-resolved localized formats (see
    ///   ``CommandPaletteSettingToggleStrings``).
    public func commandTitle(
        strings: CommandPaletteSettingToggleStrings,
        defaults: UserDefaults = .standard
    ) -> String {
        let format = isOn(defaults) ? strings.disableTitleFormat : strings.enableTitleFormat
        return String.localizedStringWithFormat(format, title())
    }

    /// The "%@ • %@" command subtitle (section title and on/off state).
    ///
    /// - Parameter strings: App-resolved localized formats (see
    ///   ``CommandPaletteSettingToggleStrings``).
    public func commandSubtitle(
        strings: CommandPaletteSettingToggleStrings,
        defaults: UserDefaults = .standard
    ) -> String {
        let state = isOn(defaults) ? strings.onState : strings.offState
        return String.localizedStringWithFormat(strings.subtitleFormat, sectionTitle(), state)
    }

    /// Flips the setting when available; a no-op when unavailable.
    public func toggle(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        guard isAvailable(defaults) else { return }
        setOn(!isOn(defaults), defaults, notificationCenter)
    }
}
