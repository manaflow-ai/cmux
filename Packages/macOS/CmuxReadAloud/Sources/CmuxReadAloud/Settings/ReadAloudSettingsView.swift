import SwiftUI

/// Presents native speech preferences, Keychain credential entry, and explicit cloud consent.
///
/// The view loads through its injected model when presented. It never reads a saved key
/// into the secure entry field and discards any unsaved key entry when dismissed.
@MainActor
public struct ReadAloudSettingsView: View {
    @Bindable private var model: ReadAloudSettingsModel

    /// Creates a settings surface backed by the app-owned Read Aloud settings model.
    /// - Parameter model: The observable state sharing preferences with the speech coordinator.
    public init(model: ReadAloudSettingsModel) {
        self.model = model
    }

    /// The native settings controls and visible persistence results.
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "title", defaultValue: "Read Aloud", table: "ReadAloudSettings", bundle: .module))
                    .font(.title2.bold())

                speechSettings
                credentialSettings
                consentSettings

                if let message = model.errorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("ReadAloudSettingsError")
                }
                if let message = model.statusMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ReadAloudSettingsStatus")
                }
                HStack {
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(String(localized: "status.working", defaultValue: "Updating Read Aloud settings", table: "ReadAloudSettings", bundle: .module))
                    }
                    Spacer()
                    Button(String(localized: "action.reload", defaultValue: "Reload Settings", table: "ReadAloudSettings", bundle: .module)) {
                        Task { await model.perform(.load) }
                    }
                    .disabled(model.isBusy)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 620)
        .task { await model.perform(.load) }
        .onDisappear { model.apiKeyDraft = "" }
    }

    private var speechSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker(String(localized: "model.label", defaultValue: "Model", table: "ReadAloudSettings", bundle: .module), selection: $model.selectedModel) {
                    Text(String(localized: "model.turbo", defaultValue: "Turbo (speech-2.8-turbo)", table: "ReadAloudSettings", bundle: .module))
                        .tag(ReadAloudConfiguration.Model.turbo)
                    Text(String(localized: "model.hd", defaultValue: "HD (speech-2.8-hd)", table: "ReadAloudSettings", bundle: .module))
                        .tag(ReadAloudConfiguration.Model.hd)
                }
                .accessibilityIdentifier("ReadAloudModel")

                TextField(String(localized: "voice.label", defaultValue: "Voice ID", table: "ReadAloudSettings", bundle: .module), text: $model.voiceID)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ReadAloudVoiceID")
                Text(String(localized: "voice.help", defaultValue: "Use a MiniMax voice ID, such as English_expressive_narrator, or your custom voice ID.", table: "ReadAloudSettings", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Slider(value: $model.speed, in: 0.5...2, step: 0.1) {
                        Text(String(localized: "speed.label", defaultValue: "Speed", table: "ReadAloudSettings", bundle: .module))
                    }
                    .accessibilityIdentifier("ReadAloudSpeed")
                    Text(String(localized: "speed.value", defaultValue: "\(model.speed.formatted(.number.precision(.fractionLength(1))))×", table: "ReadAloudSettings", bundle: .module))
                        .monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                }
                HStack {
                    if model.hasUnsavedConfiguration {
                        Text(String(localized: "status.unsaved", defaultValue: "Unsaved speech settings", table: "ReadAloudSettings", bundle: .module))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(localized: "action.saveSettings", defaultValue: "Save Speech Settings", table: "ReadAloudSettings", bundle: .module)) {
                        Task { await model.perform(.saveConfiguration) }
                    }
                    .disabled(!model.hasUnsavedConfiguration)
                    .accessibilityIdentifier("ReadAloudSaveSettings")
                }
            }
            .padding(8)
            .disabled(model.isBusy || !model.isLoaded)
        } label: {
            Text(String(localized: "section.speech", defaultValue: "Speech", table: "ReadAloudSettings", bundle: .module))
        }
    }

    private var credentialSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(credentialStatus)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ReadAloudKeyStatus")
                SecureField(String(localized: "key.entry", defaultValue: "New MiniMax API Key", table: "ReadAloudSettings", bundle: .module), text: $model.apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ReadAloudAPIKey")
                Text(String(localized: "key.help", defaultValue: "Stored only in this Mac’s Keychain. Saved keys are never displayed here. Enter a new key to replace the saved key.", table: "ReadAloudSettings", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "action.removeKey", defaultValue: "Remove API Key", table: "ReadAloudSettings", bundle: .module), role: .destructive) {
                        Task { await model.perform(.removeAPIKey) }
                    }
                    .disabled(model.hasSavedAPIKey == false)
                    .accessibilityIdentifier("ReadAloudRemoveKey")
                    Spacer()
                    Button(String(localized: "action.saveKey", defaultValue: "Save API Key", table: "ReadAloudSettings", bundle: .module)) {
                        Task { await model.perform(.saveAPIKey) }
                    }
                    .disabled(!model.canSaveAPIKey)
                    .accessibilityIdentifier("ReadAloudSaveKey")
                }
            }
            .padding(8)
            .disabled(model.isBusy || !model.isLoaded)
        } label: {
            Text(String(localized: "section.key", defaultValue: "MiniMax Credential", table: "ReadAloudSettings", bundle: .module))
        }
    }

    private var consentSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "consent.disclosure", defaultValue: "Read Aloud sends only the terminal text you select to MiniMax to generate speech. MiniMax bills usage to your account. cmux streams the audio without saving selected text or audio to a disk cache.", table: "ReadAloudSettings", bundle: .module))
                Toggle(String(localized: "consent.allow", defaultValue: "Allow sending selected text to MiniMax", table: "ReadAloudSettings", bundle: .module), isOn: Binding(
                    get: { model.consentGranted },
                    set: { granted in Task { await model.perform(.setConsent(granted)) } }
                ))
                .accessibilityIdentifier("ReadAloudConsent")
                Text(String(localized: "consent.help", defaultValue: "Optional. Read Aloud remains unavailable until you opt in and save an API key. Turn this off to prevent future requests.", table: "ReadAloudSettings", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .disabled(model.isBusy || !model.isLoaded)
        } label: {
            Text(String(localized: "section.privacy", defaultValue: "Cloud Processing Consent", table: "ReadAloudSettings", bundle: .module))
        }
    }

    private var credentialStatus: String {
        switch model.hasSavedAPIKey {
        case true?:
            String(localized: "key.saved", defaultValue: "An API key is saved in Keychain.", table: "ReadAloudSettings", bundle: .module)
        case false?:
            String(localized: "key.missing", defaultValue: "No API key is saved.", table: "ReadAloudSettings", bundle: .module)
        case nil:
            String(localized: "key.unknown", defaultValue: "Saved API key status is not yet available.", table: "ReadAloudSettings", bundle: .module)
        }
    }
}
