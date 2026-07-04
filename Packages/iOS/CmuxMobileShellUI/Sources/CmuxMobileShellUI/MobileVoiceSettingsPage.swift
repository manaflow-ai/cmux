#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import CmuxVoice
import SwiftUI

struct MobileVoiceSettingsPage: View {
    @Environment(VoiceSettingsStore.self) private var voiceSettings
    @Environment(ParakeetModelStore.self) private var parakeetModelStore

    let canOpenVoiceMode: Bool
    let openVoiceMode: () -> Void

    var body: some View {
        Form {
            Section(L10n.string("mobile.settings.voice.engine", defaultValue: "Engine")) {
                engineButton(.apple)
                engineButton(.parakeetV3)
            }

            Section {
                downloadRow
            } header: {
                Text(L10n.string("mobile.settings.voice.parakeet", defaultValue: "Parakeet v3"))
            } footer: {
                Text(L10n.string("mobile.settings.voice.footer", defaultValue: "Voice transcription is processed on this iPhone. Apple uses the built-in recognizer; Parakeet runs from a downloaded CoreML model."))
            }

            if canOpenVoiceMode {
                Section {
                    Button(action: openVoiceMode) {
                        Label(
                            L10n.string("mobile.settings.voice.openVoiceMode", defaultValue: "Open Voice Mode"),
                            systemImage: "mic.circle"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsVoiceOpenVoiceMode")
                }
            }
        }
        .navigationTitle(L10n.string("mobile.settings.voice", defaultValue: "Voice"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileSettingsVoicePage")
    }

    private func engineButton(_ engine: VoiceEngineID) -> some View {
        Button {
            voiceSettings.selectedEngine = engine
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(engine.displayName)
                    if let size = engine.downloadSizeDescription {
                        Text(size)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if voiceSettings.selectedEngine == engine {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(engine == .parakeetV3 && !parakeetModelStore.isInstalled)
        .accessibilityIdentifier(engine == .apple ? "MobileSettingsVoiceEngineApple" : "MobileSettingsVoiceEngineParakeet")
    }

    @ViewBuilder
    private var downloadRow: some View {
        switch parakeetModelStore.state {
        case .idle:
            Button {
                parakeetModelStore.downloadModel()
            } label: {
                Label(
                    L10n.string("mobile.settings.voice.downloadParakeet", defaultValue: "Download ~480 MB"),
                    systemImage: "arrow.down.circle"
                )
            }
            .accessibilityIdentifier("MobileSettingsVoiceDownloadParakeet")
        case .downloading(let progress):
            HStack {
                ProgressView(value: progress.fractionCompleted)
                Text(progressText(progress.fractionCompleted))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                    parakeetModelStore.cancelDownload()
                }
            }
            .accessibilityIdentifier("MobileSettingsVoiceDownloadProgress")
        case .installed:
            HStack {
                Label(
                    L10n.string("mobile.settings.voice.parakeetInstalled", defaultValue: "Installed"),
                    systemImage: "checkmark.circle"
                )
                Spacer()
                Button(role: .destructive) {
                    // Only flip the engine back to Apple when the files are
                    // actually gone; a failed delete leaves the model installed
                    // and the selection must keep matching reality.
                    if (try? parakeetModelStore.deleteModel()) != nil,
                       voiceSettings.selectedEngine == .parakeetV3 {
                        voiceSettings.selectedEngine = .apple
                    }
                } label: {
                    Text(L10n.string("mobile.common.delete", defaultValue: "Delete"))
                }
            }
            .accessibilityIdentifier("MobileSettingsVoiceParakeetInstalled")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .foregroundStyle(.red)
                Button {
                    parakeetModelStore.downloadModel()
                } label: {
                    Label(
                        L10n.string("mobile.common.retry", defaultValue: "Retry"),
                        systemImage: "arrow.clockwise"
                    )
                }
            }
            .accessibilityIdentifier("MobileSettingsVoiceParakeetFailed")
        }
    }

    private func progressText(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
#endif
