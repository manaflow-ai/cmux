import CmuxSettings
import SwiftUI

/// **Sessions** section — controls how cmux restores a previous session on
/// launch and whether each terminal tab keeps its own persistent shell
/// history (grouped by project). Both settings are JSON-backed
/// (`session.*` in `~/.config/cmux/cmux.json`).
@MainActor
public struct SessionSection: View {
    @State private var restoreMode: JSONValueModel<SessionRestoreMode>
    @State private var persistShellHistory: JSONValueModel<Bool>

    public init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog
    ) {
        _restoreMode = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.session.restoreMode,
            errorLog: errorLog
        ))
        _persistShellHistory = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.session.persistShellHistory,
            errorLog: errorLog
        ))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.session", defaultValue: "Sessions"), section: .session)
            SettingsCard {
                restoreModeRow
                SettingsCardDivider()
                persistShellHistoryRow
            }
        }
        .task { startObservingSettings() }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [
            restoreMode,
            persistShellHistory,
        ]
        models.forEach { $0.startObserving() }
    }

    @ViewBuilder
    private var restoreModeRow: some View {
        SettingsCardRow(
            configurationReview: .json("session.restoreMode"),
            String(localized: "settings.session.restoreMode", defaultValue: "Restore Previous Session"),
            subtitle: restoreMode.current.modeDescription
        ) {
            Picker("", selection: Binding(get: { restoreMode.current }, set: { restoreMode.set($0) })) {
                ForEach(SessionRestoreMode.uiCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("SettingsSessionRestoreModePicker")
        }
    }

    @ViewBuilder
    private var persistShellHistoryRow: some View {
        SettingsCardRow(
            configurationReview: .json("session.persistShellHistory"),
            String(localized: "settings.session.persistShellHistory", defaultValue: "Per-Tab Shell History"),
            subtitle: persistShellHistory.current
                ? String(localized: "settings.session.persistShellHistory.subtitleOn", defaultValue: "Each tab keeps its own command history (up-arrow / Ctrl-R), grouped by project, and records a cmux command history.")
                : String(localized: "settings.session.persistShellHistory.subtitleOff", defaultValue: "Tabs use your shell's normal global history (e.g. ~/.zsh_history).")
        ) {
            Toggle("", isOn: Binding(get: { persistShellHistory.current }, set: { persistShellHistory.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsSessionPersistShellHistoryToggle")
        }
    }
}
