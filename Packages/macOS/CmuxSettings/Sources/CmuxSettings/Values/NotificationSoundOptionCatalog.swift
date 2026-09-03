import Foundation

/// The localized catalog shared by notification sound settings controls.
nonisolated public struct NotificationSoundOptionCatalog: Sendable {
    /// Picker options in their stable user-facing order.
    public let options: [NotificationSoundOptionDescriptor]

    /// Creates the complete built-in and sentinel sound catalog.
    public init() {
        options = [
            .init(value: NotificationSoundOverride.defaultValue, localizationKey: "settings.notifications.sound.option.default", defaultLabel: "Default"),
            .init(value: "Basso", localizationKey: "settings.notifications.sound.option.basso", defaultLabel: "Basso"),
            .init(value: "Blow", localizationKey: "settings.notifications.sound.option.blow", defaultLabel: "Blow"),
            .init(value: "Bottle", localizationKey: "settings.notifications.sound.option.bottle", defaultLabel: "Bottle"),
            .init(value: "Frog", localizationKey: "settings.notifications.sound.option.frog", defaultLabel: "Frog"),
            .init(value: "Funk", localizationKey: "settings.notifications.sound.option.funk", defaultLabel: "Funk"),
            .init(value: "Glass", localizationKey: "settings.notifications.sound.option.glass", defaultLabel: "Glass"),
            .init(value: "Hero", localizationKey: "settings.notifications.sound.option.hero", defaultLabel: "Hero"),
            .init(value: "Morse", localizationKey: "settings.notifications.sound.option.morse", defaultLabel: "Morse"),
            .init(value: "Ping", localizationKey: "settings.notifications.sound.option.ping", defaultLabel: "Ping"),
            .init(value: "Pop", localizationKey: "settings.notifications.sound.option.pop", defaultLabel: "Pop"),
            .init(value: "Purr", localizationKey: "settings.notifications.sound.option.purr", defaultLabel: "Purr"),
            .init(value: "Sosumi", localizationKey: "settings.notifications.sound.option.sosumi", defaultLabel: "Sosumi"),
            .init(value: "Submarine", localizationKey: "settings.notifications.sound.option.submarine", defaultLabel: "Submarine"),
            .init(value: "Tink", localizationKey: "settings.notifications.sound.option.tink", defaultLabel: "Tink"),
            .init(value: NotificationSoundOverride.customFileValue, localizationKey: "settings.notifications.sound.option.customFile", defaultLabel: "Custom File…"),
            .init(value: NotificationSoundOverride.noneValue, localizationKey: "settings.notifications.sound.option.none", defaultLabel: "None"),
        ]
    }

    /// Returns the descriptor for a persisted sound value, if one exists.
    ///
    /// - Parameter value: The persisted sound value.
    /// - Returns: Its descriptor, or `nil` when the value is unsupported.
    public func descriptor(for value: String) -> NotificationSoundOptionDescriptor? {
        options.first { $0.value == value }
    }

    /// Localizes an option descriptor using the app's catalog and fallback.
    ///
    /// - Parameter descriptor: The option to localize.
    /// - Returns: The localized user-facing label.
    public func localizedLabel(for descriptor: NotificationSoundOptionDescriptor) -> String {
        String(localized: descriptor.localizationKey, defaultValue: descriptor.defaultLabel)
    }
}
