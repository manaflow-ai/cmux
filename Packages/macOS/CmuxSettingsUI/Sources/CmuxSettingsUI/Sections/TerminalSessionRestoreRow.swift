import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Settings row for the app-session terminal restore opt-out.
@MainActor
struct TerminalSessionRestoreRow: View {
    @State private var restoreTerminalSessions: DefaultsValueModel<Bool>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _restoreTerminalSessions = State(
            initialValue: DefaultsValueModel(
                store: defaultsStore,
                key: catalog.terminal.restoreTerminalSessions
            )
        )
    }

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.restoreTerminalSessions"),
            String(
                localized: "settings.terminal.restoreTerminalSessions",
                defaultValue: "Restore Terminal Sessions on Reopen"
            ),
            subtitle: restoreTerminalSessions.current
                ? String(
                    localized: "settings.terminal.restoreTerminalSessions.subtitleOn",
                    defaultValue: "When cmux reopens after quit, terminal-containing workspaces and their surfaces are restored."
                )
                : String(
                    localized: "settings.terminal.restoreTerminalSessions.subtitleOff",
                    defaultValue: "Terminal-containing workspaces are skipped on reopen; browser-only workspaces and window layout still restore."
                )
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { restoreTerminalSessions.current },
                    set: { restoreTerminalSessions.set($0) }
                )
            )
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("SettingsTerminalRestoreSessionsToggle")
        }
        .task {
            restoreTerminalSessions.startObserving()
        }
    }
}
