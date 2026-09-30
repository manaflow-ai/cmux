import CmuxSettings
import Speech
import SwiftUI

/// **Voice** section: the voice-dictation master toggle, engine (on device
/// or OpenAI with the user's key), language, shortcut behavior, agent-prompt
/// cleanup and the tab bar mic button. The copy says plainly where audio goes.
@MainActor
public struct VoiceSection: View {
    @State private var enabled: DefaultsValueModel<Bool>
    @State private var language: DefaultsValueModel<String>
    @State private var engine: DefaultsValueModel<VoiceDictationEngine>
    @State private var hotkeyMode: DefaultsValueModel<VoiceDictationHotkeyMode>
    @State private var cleanUp: DefaultsValueModel<Bool>
    @State private var showTabBarButton: DefaultsValueModel<Bool>
    @State private var availableLanguages: [VoiceDictationLanguageChoice] = []
    @State private var apiKeyDraft = ""
    @State private var hasAPIKey = false
    private let apiKeyStore: VoiceDictationAPIKeyStore

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        apiKeyStore: VoiceDictationAPIKeyStore = VoiceDictationAPIKeyStore()
    ) {
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.voice.dictationEnabled))
        _language = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.voice.dictationLanguage))
        _engine = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.voice.engine))
        _hotkeyMode = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.voice.hotkeyMode))
        _cleanUp = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.voice.cleanUpAgentPrompts))
        _showTabBarButton = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.voice.showTabBarButton))
        self.apiKeyStore = apiKeyStore
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.voice", defaultValue: "Voice"), section: .voice)
            SettingsCard {
                enabledRow
                SettingsCardDivider()
                engineRow
                SettingsCardDivider()
                languageRow
                if engine.current == .openAI {
                    SettingsCardDivider()
                    apiKeyRow
                }
                SettingsCardDivider()
                hotkeyModeRow
                SettingsCardDivider()
                cleanUpRow
                SettingsCardDivider()
                tabBarButtonRow
            }
        }
        .task {
            enabled.startObserving()
            language.startObserving()
            engine.startObserving()
            hotkeyMode.startObserving()
            cleanUp.startObserving()
            showTabBarButton.startObserving()
            hasAPIKey = apiKeyStore.hasAPIKey
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
                ? String(localized: "settings.voice.dictationEnabled.subtitleOn", defaultValue: "Press the dictation shortcut (default ⌃⌘V) or the mic button to speak into the focused pane. The text is pasted, never typed as keystrokes.")
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
        .disabled(!Self.languageRowIsEnabled(for: engine.current))
    }
}

extension VoiceSection {
    /// The language row remains indexed for both engines, but OpenAI does not
    /// use the on-device language model.
    static func languageRowIsEnabled(for engine: VoiceDictationEngine) -> Bool {
        engine != .openAI
    }
}

extension VoiceSection {
    @ViewBuilder
    var engineRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:voice:engine",
            String(localized: "settings.voice.engine", defaultValue: "Speech Engine", bundle: .module),
            subtitle: engine.current == .openAI
                ? String(localized: "settings.voice.engine.subtitleOpenAI", defaultValue: "Audio is sent to OpenAI with your API key when you stop speaking. Best accuracy; no live preview.", bundle: .module)
                : String(localized: "settings.voice.engine.subtitleOnDevice", defaultValue: "Speech is transcribed on this Mac with a live preview. No audio leaves the device.", bundle: .module)
        ) {
            Picker("", selection: Binding(get: { engine.current }, set: { engine.set($0) })) {
                Text(String(localized: "settings.voice.engine.onDevice", defaultValue: "On This Mac", bundle: .module))
                    .tag(VoiceDictationEngine.onDevice)
                Text(String(localized: "settings.voice.engine.openAI", defaultValue: "OpenAI (cloud)", bundle: .module))
                    .tag(VoiceDictationEngine.openAI)
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 220)
            .accessibilityIdentifier("SettingsVoiceDictationEnginePicker")
        }
    }

    @ViewBuilder
    var apiKeyRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.voice.openAIKey", defaultValue: "OpenAI API Key", bundle: .module),
            subtitle: hasAPIKey
                ? String(localized: "settings.voice.openAIKey.saved", defaultValue: "Saved in your Keychain.", bundle: .module)
                : String(localized: "settings.voice.openAIKey.missing", defaultValue: "Paste a key from platform.openai.com. It is stored in your Keychain, never in cmux.json.", bundle: .module)
        ) {
            HStack(spacing: 6) {
                SecureField(
                    String(localized: "settings.voice.openAIKey", defaultValue: "OpenAI API Key", bundle: .module),
                    text: $apiKeyDraft
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 160)
                .accessibilityIdentifier("SettingsVoiceDictationAPIKeyField")
                Button(String(localized: "settings.voice.openAIKey.save", defaultValue: "Save", bundle: .module)) {
                    // Keep the draft when the Keychain write fails so the
                    // row still reads "not saved" with the key in place.
                    if apiKeyStore.setAPIKey(apiKeyDraft) {
                        apiKeyDraft = ""
                    }
                    hasAPIKey = apiKeyStore.hasAPIKey
                }
                .controlSize(.small)
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasAPIKey {
                    Button(String(localized: "settings.voice.openAIKey.remove", defaultValue: "Remove", bundle: .module)) {
                        apiKeyStore.setAPIKey(nil)
                        hasAPIKey = apiKeyStore.hasAPIKey
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    var hotkeyModeRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:voice:hotkeyMode",
            String(localized: "settings.voice.hotkeyMode", defaultValue: "Shortcut Behavior", bundle: .module),
            subtitle: String(localized: "settings.voice.hotkeyMode.subtitle", defaultValue: "Automatic: a quick press toggles dictation, holding the shortcut dictates until you let go.", bundle: .module)
        ) {
            Picker("", selection: Binding(get: { hotkeyMode.current }, set: { hotkeyMode.set($0) })) {
                Text(String(localized: "settings.voice.hotkeyMode.automatic", defaultValue: "Automatic", bundle: .module))
                    .tag(VoiceDictationHotkeyMode.automatic)
                Text(String(localized: "settings.voice.hotkeyMode.toggle", defaultValue: "Press to Toggle", bundle: .module))
                    .tag(VoiceDictationHotkeyMode.toggle)
                Text(String(localized: "settings.voice.hotkeyMode.hold", defaultValue: "Hold to Talk", bundle: .module))
                    .tag(VoiceDictationHotkeyMode.hold)
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 220)
            .accessibilityIdentifier("SettingsVoiceDictationHotkeyModePicker")
        }
    }

    @ViewBuilder
    var cleanUpRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:voice:cleanUpAgentPrompts",
            String(localized: "settings.voice.cleanUpAgentPrompts", defaultValue: "Clean Up Agent Prompts", bundle: .module),
            subtitle: String(localized: "settings.voice.cleanUpAgentPrompts.subtitle", defaultValue: "Remove fillers like “um” and “uh” when dictating to a coding agent.", bundle: .module)
        ) {
            Toggle("", isOn: Binding(get: { cleanUp.current }, set: { cleanUp.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsVoiceDictationCleanUpToggle")
        }
    }

    @ViewBuilder
    var tabBarButtonRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:voice:showTabBarButton",
            String(localized: "settings.voice.showTabBarButton", defaultValue: "Mic Button in Tab Bar", bundle: .module),
            subtitle: String(localized: "settings.voice.showTabBarButton.subtitle", defaultValue: "Show a microphone button next to the new tab and split buttons.", bundle: .module)
        ) {
            Toggle("", isOn: Binding(get: { showTabBarButton.current }, set: { showTabBarButton.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsVoiceDictationTabBarButtonToggle")
        }
    }
}

/// One selectable dictation language.
struct VoiceDictationLanguageChoice: Identifiable, Hashable, Sendable {
    let identifier: String
    let displayName: String

    var id: String { identifier }

    /// Languages the current OS can transcribe on device, sorted by
    /// localized display name.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    static func systemChoices() async -> [VoiceDictationLanguageChoice] {
        var locales: [Locale]?
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            locales = await SpeechTranscriber.supportedLocales
        }
        #endif
        let supported: [Locale] = locales ?? SFSpeechRecognizer.supportedLocales().filter { locale in
            // The system list also contains languages that can only use
            // Apple's network recognizer. Voice dictation promises
            // on-device processing, so do not offer those choices.
            guard let recognizer = SFSpeechRecognizer(locale: locale),
                  recognizer.locale.identifier(.bcp47) == locale.identifier(.bcp47)
            else { return false }
            return recognizer.supportsOnDeviceRecognition
        }
        let current = Locale.current
        return supported
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
