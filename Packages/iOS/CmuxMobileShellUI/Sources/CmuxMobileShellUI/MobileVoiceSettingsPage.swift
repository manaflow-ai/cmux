#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import CmuxVoice
import SwiftUI

struct MobileVoiceSettingsPage: View {
    @Environment(VoiceSettingsStore.self) private var voiceSettings
    @Environment(ParakeetModelCatalogStore.self) private var modelCatalog

    let canOpenVoiceMode: Bool
    let openVoiceMode: () -> Void

    var body: some View {
        let appleRow = appleEngineRow(selectedEngine: voiceSettings.selectedEngine)
        let downloadableRows = downloadableEngineRows(
            selectedEngine: voiceSettings.selectedEngine,
            stores: modelCatalog.stores,
            anyDownloadInProgress: modelCatalog.isDownloadingAnyModel
        )
        let actions = VoiceEngineRowActions(
            select: { engine in voiceSettings.selectedEngine = engine },
            download: { engine in modelCatalog.downloadModel(for: engine) },
            cancel: { engine in modelCatalog.store(for: engine)?.cancelDownload() },
            delete: { engine in deleteModel(for: engine) }
        )

        Form {
            Section {
                VoiceEngineSettingsRow(row: appleRow, actions: actions)
            } header: {
                Text(L10n.string("mobile.settings.voice.appleSection", defaultValue: "Apple"))
            }

            Section {
                ForEach(downloadableRows) { row in
                    VoiceEngineSettingsRow(row: row, actions: actions)
                }
            } header: {
                Text(L10n.string("mobile.settings.voice.downloadableSection", defaultValue: "Downloadable models"))
            } footer: {
                Text(L10n.string("mobile.settings.voice.footer", defaultValue: "Parakeet always transcribes on this iPhone from a downloaded CoreML model. The Apple engine prefers on-device recognition; when your language does not support it, Apple's servers may process the audio."))
            }

            Section {
                NavigationLink {
                    MobileVoiceVocabularySettingsPage()
                } label: {
                    Label(
                        L10n.string("mobile.settings.voice.vocabulary", defaultValue: "Custom Vocabulary"),
                        systemImage: "text.badge.plus"
                    )
                }
                .accessibilityIdentifier("MobileSettingsVoiceVocabulary")
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

    private func deleteModel(for engine: VoiceEngineID) {
        // Only flip the engine back to Apple when the files are actually gone; a
        // failed delete leaves the model installed and the selection matching reality.
        if (try? modelCatalog.deleteModel(for: engine)) != nil,
           voiceSettings.selectedEngine == engine {
            voiceSettings.selectedEngine = .apple
        }
    }

    private func appleEngineRow(selectedEngine: VoiceEngineID) -> VoiceEngineSettingsRowModel {
        VoiceEngineSettingsRowModel(
            engine: .apple,
            displayName: VoiceEngineID.apple.displayName,
            caption: nil,
            downloadSizeDescription: nil,
            isSelected: selectedEngine == .apple,
            isSelectable: true,
            isDownloadEnabled: false,
            accessory: .none,
            accessibilityIdentifier: "MobileSettingsVoiceEngineApple",
            downloadAccessibilityIdentifier: nil,
            deleteAccessibilityIdentifier: nil,
            failedAccessibilityIdentifier: nil
        )
    }

    private func downloadableEngineRows(
        selectedEngine: VoiceEngineID,
        stores: [ParakeetModelStore],
        anyDownloadInProgress: Bool
    ) -> [VoiceEngineSettingsRowModel] {
        stores.map { store in
            let engine = store.engineID
            let installed = store.isInstalled
            return VoiceEngineSettingsRowModel(
                engine: engine,
                displayName: engine.displayName,
                caption: engine.caption,
                downloadSizeDescription: engine.downloadSizeDescription,
                isSelected: selectedEngine == engine && installed,
                isSelectable: installed,
                isDownloadEnabled: !anyDownloadInProgress || store.state.isDownloading,
                accessory: parakeetAccessory(for: store.state),
                accessibilityIdentifier: accessibilityIdentifier(for: engine),
                downloadAccessibilityIdentifier: downloadAccessibilityIdentifier(for: engine),
                deleteAccessibilityIdentifier: deleteAccessibilityIdentifier(for: engine),
                failedAccessibilityIdentifier: failedAccessibilityIdentifier(for: engine)
            )
        }
    }

    private func parakeetAccessory(for state: ParakeetDownloadState) -> VoiceEngineAccessory {
        switch state {
        case .idle:
            return .download
        case .downloading(let progress):
            return .downloading(progress)
        case .installed:
            return .installed
        case .failed(let message):
            return .failed(message)
        }
    }

    private func accessibilityIdentifier(for engine: VoiceEngineID) -> String {
        switch engine {
        case .apple:
            return "MobileSettingsVoiceEngineApple"
        case .parakeetV3:
            return "MobileSettingsVoiceEngineParakeet"
        case .parakeetV3Int4:
            return "MobileSettingsVoiceEngineParakeetCompact"
        case .parakeetV2:
            return "MobileSettingsVoiceEngineParakeetV2"
        }
    }

    private func downloadAccessibilityIdentifier(for engine: VoiceEngineID) -> String? {
        switch engine {
        case .apple:
            return nil
        case .parakeetV3:
            return "MobileSettingsVoiceDownloadParakeet"
        case .parakeetV3Int4:
            return "MobileSettingsVoiceDownloadParakeetCompact"
        case .parakeetV2:
            return "MobileSettingsVoiceDownloadParakeetV2"
        }
    }

    private func deleteAccessibilityIdentifier(for engine: VoiceEngineID) -> String? {
        switch engine {
        case .apple:
            return nil
        case .parakeetV3:
            return "MobileSettingsVoiceDeleteParakeet"
        case .parakeetV3Int4:
            return "MobileSettingsVoiceDeleteParakeetCompact"
        case .parakeetV2:
            return "MobileSettingsVoiceDeleteParakeetV2"
        }
    }

    private func failedAccessibilityIdentifier(for engine: VoiceEngineID) -> String? {
        switch engine {
        case .apple:
            return nil
        case .parakeetV3:
            return "MobileSettingsVoiceParakeetFailed"
        case .parakeetV3Int4:
            return "MobileSettingsVoiceParakeetCompactFailed"
        case .parakeetV2:
            return "MobileSettingsVoiceParakeetV2Failed"
        }
    }
}

private struct VoiceEngineSettingsRowModel: Identifiable, Equatable {
    let engine: VoiceEngineID
    let displayName: String
    let caption: String?
    let downloadSizeDescription: String?
    let isSelected: Bool
    let isSelectable: Bool
    let isDownloadEnabled: Bool
    let accessory: VoiceEngineAccessory
    let accessibilityIdentifier: String
    let downloadAccessibilityIdentifier: String?
    let deleteAccessibilityIdentifier: String?
    let failedAccessibilityIdentifier: String?

    var id: VoiceEngineID { engine }
}

private enum VoiceEngineAccessory: Equatable {
    case none
    case download
    case downloading(ParakeetDownloadProgress)
    case installed
    case failed(String)
}

private struct VoiceEngineRowActions {
    let select: (VoiceEngineID) -> Void
    let download: (VoiceEngineID) -> Void
    let cancel: (VoiceEngineID) -> Void
    let delete: (VoiceEngineID) -> Void
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
                        if let caption = row.caption {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                    actions.delete(row.engine)
                } label: {
                    Label(
                        L10n.string("mobile.common.delete", defaultValue: "Delete"),
                        systemImage: "trash"
                    )
                }
                .accessibilityIdentifier(row.deleteAccessibilityIdentifier ?? "MobileSettingsVoiceDeleteModel")
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
                    actions.download(row.engine)
                } label: {
                    Text(L10n.string("mobile.settings.voice.getModel", defaultValue: "Get"))
                }
                .buttonStyle(.bordered)
                .disabled(!row.isDownloadEnabled)
                .accessibilityIdentifier(row.downloadAccessibilityIdentifier ?? "MobileSettingsVoiceDownloadModel")

                if let downloadSizeDescription = row.downloadSizeDescription {
                    Text(downloadSizeDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .downloading(let progress):
            HStack(spacing: 8) {
                // Listing (HuggingFace tree enumeration) and CoreML compilation
                // have no meaningful byte fraction; show an indeterminate spinner
                // with a phase label instead of a bar frozen at 0% or 100%.
                if progress.phaseDescription == "downloading" {
                    ProgressView(value: progress.fractionCompleted)
                        .frame(width: 72)
                    Text(progressText(progress.fractionCompleted))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress.phaseDescription == "compiling"
                        ? L10n.string("mobile.settings.voice.optimizing", defaultValue: "Optimizing…")
                        : L10n.string("mobile.settings.voice.preparing", defaultValue: "Preparing…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                    actions.cancel(row.engine)
                }
                .buttonStyle(.bordered)
            }
            .accessibilityIdentifier("MobileSettingsVoiceDownloadProgress")
        case .installed:
            Button(role: .destructive) {
                actions.delete(row.engine)
            } label: {
                Text(L10n.string("mobile.common.delete", defaultValue: "Delete"))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(row.deleteAccessibilityIdentifier ?? "MobileSettingsVoiceDeleteModel")
        case .failed:
            Button {
                actions.download(row.engine)
            } label: {
                Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
            }
            .buttonStyle(.bordered)
            .disabled(!row.isDownloadEnabled)
            .accessibilityIdentifier(row.failedAccessibilityIdentifier ?? "MobileSettingsVoiceModelFailed")
        }
    }

    private func progressText(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
#endif
