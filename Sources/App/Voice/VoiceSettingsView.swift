import SwiftUI

struct VoiceSettingsView: View {
    @State private var apiKeyInput: String = ""
    @State private var isKeyMasked: Bool = true
    @State private var saveStatus: String = ""
    @State private var statusTask: Task<Void, Never>? = nil
    @State private var saveStatusIsError: Bool = false
    @AppStorage("voice.autoStart") private var autoStart: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "settings.voice.autoStart",
                           defaultValue: "Start voice input automatically on launch"),
                    isOn: $autoStart
                )
            }
            Section {
                HStack {
                    if isKeyMasked {
                        SecureField(
                            String(localized: "settings.voice.apiKeyPlaceholder",
                                   defaultValue: "sk-…"),
                            text: $apiKeyInput
                        )
                    } else {
                        TextField(
                            String(localized: "settings.voice.apiKeyPlaceholder",
                                   defaultValue: "sk-…"),
                            text: $apiKeyInput
                        )
                    }
                    Button {
                        isKeyMasked.toggle()
                    } label: {
                        Image(systemName: isKeyMasked ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isKeyMasked
                        ? String(localized: "settings.voice.showKey", defaultValue: "Show API key")
                        : String(localized: "settings.voice.hideKey", defaultValue: "Hide API key"))
                }
                HStack {
                    Button(String(localized: "settings.voice.saveKey",
                                  defaultValue: "Save API Key")) {
                        saveKey()
                    }
                    if !saveStatus.isEmpty {
                        Text(saveStatus)
                            .foregroundStyle(saveStatusIsError ? .red : .secondary)
                            .font(.caption)
                    }
                }
                Button(String(localized: "settings.voice.clearKey",
                              defaultValue: "Clear API Key"),
                       role: .destructive) {
                    clearKey()
                }
            } header: {
                Text(String(localized: "settings.voice.apiKeySection",
                            defaultValue: "OpenAI API Key"))
            } footer: {
                Text(String(localized: "settings.voice.apiKeyFooter",
                            defaultValue: "Your key is stored in the macOS Keychain and never leaves your device."))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if apiKeyInput.isEmpty, let existing = VoiceKeychainStore.load() {
                apiKeyInput = existing
            }
        }
    }

    private func saveKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            saveStatusIsError = true
            saveStatus = String(localized: "settings.voice.emptyKey", defaultValue: "Enter a key first")
            statusTask?.cancel()
            statusTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                saveStatus = ""
            }
            return
        }
        do {
            try VoiceKeychainStore.save(trimmed)
            saveStatusIsError = false
            saveStatus = String(localized: "settings.voice.saved", defaultValue: "Saved")
            statusTask?.cancel()
            statusTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                saveStatus = ""
            }
        } catch {
            saveStatusIsError = true
            saveStatus = error.localizedDescription
        }
    }

    private func clearKey() {
        VoiceKeychainStore.delete()
        apiKeyInput = ""
        saveStatusIsError = false
        saveStatus = String(localized: "settings.voice.cleared", defaultValue: "Cleared")
        statusTask?.cancel()
        statusTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            saveStatus = ""
        }
    }
}
