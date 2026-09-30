import Foundation

/// Settings for cmux voice dictation (the `voice.*` keys).
///
/// Dictation transcribes speech (on device by default) and pastes it into
/// the focused pane; these keys gate the feature and pick its engine,
/// language and shortcut behavior.
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

    /// Speech engine. On device by default; the OpenAI engine is opt-in and
    /// needs an API key saved from Settings.
    public let engine = DefaultsKey<VoiceDictationEngine>(
        id: "voice.engine",
        defaultValue: .onDevice,
        userDefaultsKey: "voice.engine"
    )

    /// OpenAI transcription model for the cloud engine. Empty means the
    /// built-in default (`gpt-transcribe`).
    public let openAIModel = DefaultsKey<String>(
        id: "voice.openAIModel",
        defaultValue: "",
        userDefaultsKey: "voice.openAIModel"
    )

    /// Tap-to-toggle, hold-to-talk, or both (a quick press toggles, a long
    /// press dictates until release).
    public let hotkeyMode = DefaultsKey<VoiceDictationHotkeyMode>(
        id: "voice.hotkeyMode",
        defaultValue: .automatic,
        userDefaultsKey: "voice.hotkeyMode"
    )

    /// Remove spoken fillers ("um", "uh") when dictating into an agent
    /// prompt (a terminal running a coding agent, or the agent chat view).
    public let cleanUpAgentPrompts = DefaultsKey<Bool>(
        id: "voice.cleanUpAgentPrompts",
        defaultValue: true,
        userDefaultsKey: "voice.cleanUpAgentPrompts"
    )

    /// Show the microphone button in the surface tab bar while dictation
    /// is enabled.
    public let showTabBarButton = DefaultsKey<Bool>(
        id: "voice.showTabBarButton",
        defaultValue: true,
        userDefaultsKey: "voice.showTabBarButton"
    )

    public init() {}
}
