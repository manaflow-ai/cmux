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
        let rows = voiceEngineRows(
            selectedEngine: voiceSettings.selectedEngine,
            parakeetState: parakeetModelStore.state,
            parakeetInstalled: parakeetModelStore.isInstalled
        )
        let actions = VoiceEngineRowActions(
            select: { engine in voiceSettings.selectedEngine = engine },
            download: { parakeetModelStore.downloadModel() },
            cancel: { parakeetModelStore.cancelDownload() },
            delete: { deleteParakeetModel() }
        )

        Form {
            Section {
                ForEach(rows) { row in
                    VoiceEngineSettingsRow(row: row, actions: actions)
                }
            } header: {
                Text(L10n.string("mobile.settings.voice.engine", defaultValue: "Engine"))
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

    private func deleteParakeetModel() {
        // Only flip the engine back to Apple when the files are actually gone; a
        // failed delete leaves the model installed and the selection matching reality.
        if (try? parakeetModelStore.deleteModel()) != nil,
           voiceSettings.selectedEngine == .parakeetV3 {
            voiceSettings.selectedEngine = .apple
        }
    }

    private func voiceEngineRows(
        selectedEngine: VoiceEngineID,
        parakeetState: ParakeetDownloadState,
        parakeetInstalled: Bool
    ) -> [VoiceEngineSettingsRowModel] {
        VoiceEngineID.allCases.map { engine in
            switch engine {
            case .apple:
                return VoiceEngineSettingsRowModel(
                    engine: engine,
                    displayName: engine.displayName,
                    downloadSizeDescription: nil,
                    isSelected: selectedEngine == engine,
                    isSelectable: true,
                    accessory: .none,
                    accessibilityIdentifier: "MobileSettingsVoiceEngineApple"
                )
            case .parakeetV3:
                return VoiceEngineSettingsRowModel(
                    engine: engine,
                    displayName: engine.displayName,
                    downloadSizeDescription: engine.downloadSizeDescription,
                    isSelected: selectedEngine == engine && parakeetInstalled,
                    isSelectable: parakeetInstalled,
                    accessory: parakeetAccessory(for: parakeetState),
                    accessibilityIdentifier: "MobileSettingsVoiceEngineParakeet"
                )
            }
        }
    }

    private func parakeetAccessory(for state: ParakeetDownloadState) -> VoiceEngineAccessory {
        switch state {
        case .idle:
            return .download
        case .downloading(let progress):
            return .downloading(progress.fractionCompleted)
        case .installed:
            return .installed
        case .failed(let message):
            return .failed(message)
        }
    }
}

private struct VoiceEngineSettingsRowModel: Identifiable, Equatable {
    let engine: VoiceEngineID
    let displayName: String
    let downloadSizeDescription: String?
    let isSelected: Bool
    let isSelectable: Bool
    let accessory: VoiceEngineAccessory
    let accessibilityIdentifier: String

    var id: VoiceEngineID { engine }
}

private enum VoiceEngineAccessory: Equatable {
    case none
    case download
    case downloading(Double)
    case installed
    case failed(String)
}

private struct VoiceEngineRowActions {
    let select: (VoiceEngineID) -> Void
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void
}

private struct VoiceEngineSettingsRow: View {
    let row: VoiceEngineSettingsRowModel
    let actions: VoiceEngineRowActions

    var body: some View {
        HStack(spacing: 12) {
            Button {
                guard row.isSelectable else { return }
                actions.select(row.engine)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.displayName)
                            .foregroundStyle(row.isSelectable ? .primary : .secondary)
                        if let downloadSizeDescription = row.downloadSizeDescription {
                            Text(downloadSizeDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if case .failed(let message) = row.accessory {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer(minLength: 8)
                    if row.isSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!row.isSelectable)

            accessoryView
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if row.accessory == .installed {
                Button(role: .destructive) {
                    actions.delete()
                } label: {
                    Label(
                        L10n.string("mobile.common.delete", defaultValue: "Delete"),
                        systemImage: "trash"
                    )
                }
                .accessibilityIdentifier("MobileSettingsVoiceDeleteParakeet")
            }
        }
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch row.accessory {
        case .none:
            EmptyView()
        case .download:
            VStack(alignment: .trailing, spacing: 3) {
                Button {
                    actions.download()
                } label: {
                    Text(L10n.string("mobile.settings.voice.getModel", defaultValue: "Get"))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("MobileSettingsVoiceDownloadParakeet")

                if let downloadSizeDescription = row.downloadSizeDescription {
                    Text(downloadSizeDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 72)
                Text(progressText(progress))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                    actions.cancel()
                }
                .buttonStyle(.bordered)
            }
            .accessibilityIdentifier("MobileSettingsVoiceDownloadProgress")
        case .installed:
            Button(role: .destructive) {
                actions.delete()
            } label: {
                Text(L10n.string("mobile.common.delete", defaultValue: "Delete"))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobileSettingsVoiceDeleteParakeet")
        case .failed:
            Button {
                actions.download()
            } label: {
                Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobileSettingsVoiceParakeetFailed")
        }
    }

    private func progressText(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
#endif
