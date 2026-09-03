import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Settings row for the app-session terminal restore opt-out.
@MainActor
struct TerminalSessionRestoreRow: View {
    @State private var restoreTerminalSessions: DefaultsValueModel<Bool>
    private let afterCommit: @MainActor @Sendable () -> Void

    /// Creates a row backed by the injected defaults store and host callback.
    init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        afterCommit: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.afterCommit = afterCommit
        _restoreTerminalSessions = State(
            initialValue: DefaultsValueModel(
                store: defaultsStore,
                key: catalog.terminal.restoreTerminalSessions
            )
        )
    }

    /// Renders the localized title, state-dependent explanation, and switch.
    var body: some View {
        let title = String(
            localized: "settings.terminal.restoreTerminalSessions",
            defaultValue: "Restore Terminal Sessions on Reopen"
        )
        SettingsCardRow(
            configurationReview: .json("terminal.restoreTerminalSessions"),
            title,
            subtitle: restoreTerminalSessions.current
                ? String(
                    localized: "settings.terminal.restoreTerminalSessions.subtitleOn",
                    defaultValue: "When cmux reopens after quit, terminal-containing workspaces and their surfaces are restored."
                )
                : String(
                    localized: "settings.terminal.restoreTerminalSessions.subtitleOff",
                    defaultValue: "Automatic restoration skips terminal-containing workspaces and terminal surfaces, including dock panels, while preserving browser-only workspaces and window layout."
                )
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { restoreTerminalSessions.current },
                    set: { restoreTerminalSessions.set($0, afterCommit: afterCommit) }
                )
            )
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityIdentifier("SettingsTerminalRestoreSessionsToggle")
        }
        .task {
            restoreTerminalSessions.startObserving()
        }
    }
}
