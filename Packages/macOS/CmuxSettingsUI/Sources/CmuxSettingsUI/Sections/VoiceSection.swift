import CmuxSettings
import Speech
import SwiftUI

/// **Voice** section — the voice-dictation master toggle and language
/// picker. Dictation is fully on-device; the copy says so explicitly.
@MainActor
public struct VoiceSection: View {
    @State private var enabled: DefaultsValueModel<Bool>
    @State private var language: DefaultsValueModel<String>
    @State private var availableLanguages: [VoiceDictationLanguageChoice] = []

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.voice.dictationEnabled))
        _language = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.voice.dictationLanguage))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.voice", defaultValue: "Voice"), section: .voice)
            SettingsCard {
                enabledRow
                SettingsCardDivider()
                languageRow
            }
        }
        .task {
            enabled.startObserving()
            language.startObserving()
            availableLanguages = await VoiceDictationLanguageChoice.systemChoices()
        }
    }

    @ViewBuilder
    private var enabledRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:voice:dictationEnabled",
            String(localized: "settings.voice.dictationEnabled", defaultValue: "Voice Dictation"),
            subtitle: enabled.current
                ? String(localized: "settings.voice.dictationEnabled.subtitleOn", defaultValue: "Press the dictation shortcut (default ⌃⌘V) to speak into the focused pane. Speech is transcribed on this Mac and never leaves the device.")
                : String(localized: "settings.voice.dictationEnabled.subtitleOff", defaultValue: "The dictation shortcut is inert until you enable voice dictation here.")
        ) {
            Toggle("", isOn: Binding(get: { enabled.current }, set: { enabled.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsVoiceDictationToggle")
        }
    }

    @ViewBuilder
    private var languageRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:voice:dictationLanguage",
            String(localized: "settings.voice.dictationLanguage", defaultValue: "Dictation Language"),
            subtitle: String(localized: "settings.voice.dictationLanguage.subtitle", defaultValue: "Languages with on-device speech recognition on this Mac. The model downloads on first use.")
        ) {
            Picker("", selection: Binding(get: { language.current }, set: { language.set($0) })) {
                Text(String(localized: "settings.voice.dictationLanguage.system", defaultValue: "System Default"))
                    .tag("")
                ForEach(availableLanguages) { choice in
                    Text(choice.displayName).tag(choice.identifier)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 220)
            .accessibilityIdentifier("SettingsVoiceDictationLanguagePicker")
        }
    }
}

/// One selectable dictation language.
struct VoiceDictationLanguageChoice: Identifiable, Hashable {
    let identifier: String
    let displayName: String

    var id: String { identifier }

    /// Languages the current OS can transcribe on device, sorted by
    /// localized display name.
    static func systemChoices() async -> [VoiceDictationLanguageChoice] {
        let locales: [Locale]
        if #available(macOS 26.0, *) {
            locales = await SpeechTranscriber.supportedLocales
        } else {
            locales = Array(SFSpeechRecognizer.supportedLocales())
        }
        let current = Locale.current
        return locales
            .map { locale in
                VoiceDictationLanguageChoice(
                    identifier: locale.identifier,
                    displayName: current.localizedString(forIdentifier: locale.identifier)
                        ?? locale.identifier
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
