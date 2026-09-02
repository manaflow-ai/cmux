import Foundation

/// Settings for cmux voice dictation (the `voice.*` keys).
///
/// Dictation transcribes speech fully on device and types it into the
/// focused pane; these keys gate the feature and pick its language.
public struct VoiceCatalogSection: SettingCatalogSection {
    /// Master switch for voice dictation. While off, the dictation
    /// shortcut and every other entry point are inert.
    public let dictationEnabled = DefaultsKey<Bool>(
        id: "voice.dictationEnabled",
        defaultValue: true,
        userDefaultsKey: "voice.dictationEnabled"
    )

    /// BCP-47 identifier of the dictation language (for example `en-US`).
    /// Empty string means "follow the system locale".
    public let dictationLanguage = DefaultsKey<String>(
        id: "voice.dictationLanguage",
        defaultValue: "",
        userDefaultsKey: "voice.dictationLanguage"
    )

    /// Whether the one-time "Set Up Voice" explainer has been accepted.
    /// Not shown in the Settings UI; flipped by the setup dialog.
    public let dictationSetupCompleted = DefaultsKey<Bool>(
        id: "voice.dictationSetupCompleted",
        defaultValue: false,
        userDefaultsKey: "voice.dictationSetupCompleted"
    )

    public init() {}
}
