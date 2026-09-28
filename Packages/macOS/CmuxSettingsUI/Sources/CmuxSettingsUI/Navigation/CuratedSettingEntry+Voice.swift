import Foundation

extension Array where Element == CuratedSettingEntry {
    /// `entries` followed by ``voiceEntries``. A call rather than `+` keeps
    /// the default table's contextual type concrete (see
    /// ``appendingDevicesEntries(to:)``).
    static func appendingVoiceEntries(to entries: [CuratedSettingEntry]) -> [CuratedSettingEntry] {
        entries + voiceEntries
    }

    /// Search entries for the Voice section rows. Voice settings live in
    /// Settings only (not cmux.json), so the entries declare no paths and the
    /// synonyms carry no dotted tokens.
    static var voiceEntries: [CuratedSettingEntry] {
        [
            .init(section: .voice, id: "dictationEnabled", title: String(localized: "settings.voice.dictationEnabled", defaultValue: "Voice Dictation"), synonyms: "Voice Dictation voice dictation speech microphone mic speak transcribe shortcut hotkey"),
            .init(section: .voice, id: "engine", title: String(localized: "settings.voice.engine", defaultValue: "Speech Engine"), synonyms: "Speech Engine voice dictation engine openai cloud on-device whisper transcription model"),
            .init(section: .voice, id: "openAIKey", title: String(localized: "settings.voice.openAIKey", defaultValue: "OpenAI API Key"), synonyms: "OpenAI API Key voice dictation cloud key token keychain"),
            .init(section: .voice, id: "dictationLanguage", title: String(localized: "settings.voice.dictationLanguage", defaultValue: "Dictation Language"), synonyms: "Dictation Language voice dictation language locale speech recognition model"),
            .init(section: .voice, id: "hotkeyMode", title: String(localized: "settings.voice.hotkeyMode", defaultValue: "Shortcut Behavior"), synonyms: "Shortcut Behavior voice dictation hold to talk push to talk toggle hotkey"),
            .init(section: .voice, id: "cleanUpAgentPrompts", title: String(localized: "settings.voice.cleanUpAgentPrompts", defaultValue: "Clean Up Agent Prompts"), synonyms: "Clean Up Agent Prompts voice dictation filler um uh cleanup agent"),
            .init(section: .voice, id: "showTabBarButton", title: String(localized: "settings.voice.showTabBarButton", defaultValue: "Mic Button in Tab Bar"), synonyms: "Mic Button in Tab Bar voice dictation microphone button tab bar"),
        ]
    }
}
