#if os(iOS)
import CmuxMobileSupport
import CmuxVoice
import SwiftUI

struct MobileVoiceVocabularySettingsPage: View {
    @Environment(VoiceVocabularyStore.self) private var vocabularyStore
    @Environment(ParakeetVocabularyBoostStore.self) private var vocabularyBoostStore
    @State private var draftTerm = ""

    var body: some View {
        let termRows = vocabularyStore.terms.map { VoiceVocabularyTermRowModel(term: $0) }
        let autoBiasEnabled = vocabularyStore.autoBiasScreenTerms
        let boostRow = VoiceVocabularyBoostRowModel(state: vocabularyBoostStore.state)
        let actions = VoiceVocabularyActions(
            add: addDraftTerm,
            remove: { offsets in vocabularyStore.removeTerms(at: offsets) },
            setAutoBias: { vocabularyStore.autoBiasScreenTerms = $0 },
            downloadBoost: { vocabularyBoostStore.downloadModel() },
            cancelBoost: { vocabularyBoostStore.cancelDownload() },
            deleteBoost: { try? vocabularyBoostStore.deleteModel() }
        )

        List {
            Section {
                VoiceVocabularyBoostRow(row: boostRow, actions: actions)
            } footer: {
                Text(L10n.string("mobile.settings.voice.vocabularyBoost.footer", defaultValue: "Download this add-on to apply custom vocabulary to Parakeet. Apple uses custom vocabulary without a download."))
            }

            Section {
                VoiceVocabularyAddTermRow(draftTerm: $draftTerm, add: actions.add)
            } footer: {
                Text(L10n.string("mobile.settings.voice.vocabulary.footer", defaultValue: "Custom vocabulary improves recognition of technical terms, repo names, and commands."))
            }

            Section {
                VoiceVocabularyAutoBiasRow(isEnabled: autoBiasEnabled, setEnabled: actions.setAutoBias)
            } footer: {
                Text(L10n.string("mobile.settings.voice.vocabulary.autoBiasFooter", defaultValue: "When Voice Mode starts, cmux also boosts words visible in your Mac workspace and pane titles."))
            }

            Section {
                if termRows.isEmpty {
                    Text(L10n.string("mobile.settings.voice.vocabulary.empty", defaultValue: "No terms yet"))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("MobileVoiceVocabularyEmpty")
                } else {
                    ForEach(termRows) { row in
                        VoiceVocabularyTermRow(row: row)
                    }
                    .onDelete(perform: actions.remove)
                }
            } header: {
                Text(L10n.string("mobile.settings.voice.vocabulary.terms", defaultValue: "Terms"))
            }
        }
        .navigationTitle(L10n.string("mobile.settings.voice.vocabulary", defaultValue: "Custom Vocabulary"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileVoiceVocabularyPage")
    }

    private func addDraftTerm() {
        if vocabularyStore.addTerm(draftTerm) {
            draftTerm = ""
        }
    }
}

private struct VoiceVocabularyActions {
    let add: () -> Void
    let remove: (IndexSet) -> Void
    let setAutoBias: (Bool) -> Void
    let downloadBoost: () -> Void
    let cancelBoost: () -> Void
    let deleteBoost: () -> Void
}

private struct VoiceVocabularyBoostRowModel: Equatable {
    let state: ParakeetDownloadState
}

private struct VoiceVocabularyTermRowModel: Identifiable, Equatable {
    let term: String

    var id: String { term.lowercased() }
}

private struct VoiceVocabularyAddTermRow: View {
    @Binding var draftTerm: String
    let add: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField(
                L10n.string("mobile.settings.voice.vocabulary.addPlaceholder", defaultValue: "Add term"),
                text: $draftTerm
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit(add)
            .accessibilityIdentifier("MobileVoiceVocabularyAddField")

            Button(L10n.string("mobile.settings.voice.vocabulary.addButton", defaultValue: "Add")) {
                add()
            }
            .disabled(draftTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("MobileVoiceVocabularyAddButton")
        }
    }
}

private struct VoiceVocabularyAutoBiasRow: View {
    let isEnabled: Bool
    let setEnabled: (Bool) -> Void

    var body: some View {
        Toggle(
            L10n.string("mobile.settings.voice.vocabulary.autoBias", defaultValue: "Use visible Mac terms"),
            isOn: Binding(
                get: { isEnabled },
                set: { newValue, _ in setEnabled(newValue) }
            )
        )
        .accessibilityIdentifier("MobileVoiceVocabularyAutoBias")
    }
}

private struct VoiceVocabularyBoostRow: View {
    let row: VoiceVocabularyBoostRowModel
    let actions: VoiceVocabularyActions

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("mobile.settings.voice.vocabularyBoost.title", defaultValue: "Parakeet vocabulary boost · 103 MB"))
                Text(L10n.string("mobile.settings.voice.vocabularyBoost.caption", defaultValue: "Optional CTC add-on for Parakeet custom terms"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = row.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if row.state == .installed {
                Button(role: .destructive) {
                    actions.deleteBoost()
                } label: {
                    Label(
                        L10n.string("mobile.common.delete", defaultValue: "Delete"),
                        systemImage: "trash"
                    )
                }
                .accessibilityIdentifier("MobileVoiceVocabularyBoostDelete")
            }
        }
        .accessibilityIdentifier("MobileVoiceVocabularyBoost")
    }

    @ViewBuilder
    private var accessory: some View {
        switch row.state {
        case .idle:
            Button {
                actions.downloadBoost()
            } label: {
                Text(L10n.string("mobile.settings.voice.getModel", defaultValue: "Get"))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobileVoiceVocabularyBoostDownload")
        case .downloading(let progress):
            HStack(spacing: 8) {
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
                    actions.cancelBoost()
                }
                .buttonStyle(.bordered)
            }
            .accessibilityIdentifier("MobileVoiceVocabularyBoostProgress")
        case .installed:
            Button(role: .destructive) {
                actions.deleteBoost()
            } label: {
                Text(L10n.string("mobile.common.delete", defaultValue: "Delete"))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobileVoiceVocabularyBoostDelete")
        case .failed:
            Button {
                actions.downloadBoost()
            } label: {
                Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobileVoiceVocabularyBoostRetry")
        }
    }

    private func progressText(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

private struct VoiceVocabularyTermRow: View {
    let row: VoiceVocabularyTermRowModel

    var body: some View {
        Text(row.term)
            .accessibilityIdentifier("MobileVoiceVocabularyTerm")
    }
}
#endif
