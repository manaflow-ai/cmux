import Foundation

/// Declarative metadata for one notification sound picker value.
nonisolated public struct NotificationSoundOptionDescriptor: Sendable {
    /// The persisted value consumed by runtime sound resolution.
    public let value: String
    /// The localization key for the user-facing option label.
    public let localizationKey: StaticString
    /// The English fallback used when a catalog translation is unavailable.
    public let defaultLabel: String.LocalizationValue

    /// Creates a descriptor shared by settings validation and UI controls.
    ///
    /// - Parameters:
    ///   - value: The value persisted in settings.
    ///   - localizationKey: The localized label's catalog key.
    ///   - defaultLabel: The English fallback label.
    public init(
        value: String,
        localizationKey: StaticString,
        defaultLabel: String.LocalizationValue
    ) {
        self.value = value
        self.localizationKey = localizationKey
        self.defaultLabel = defaultLabel
    }
}
