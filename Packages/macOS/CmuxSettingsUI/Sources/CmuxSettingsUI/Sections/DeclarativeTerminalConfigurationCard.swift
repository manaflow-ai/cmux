import CmuxSettings
import SwiftUI

/// Settings-card controls for the declarative defaults used by new local
/// terminal surfaces.
///
/// The card consumes one runtime-owned, presence-preserving model. Only the
/// two text drafts remain local because they must not be replaced while a
/// user is typing; committed values and external edits reconcile through the
/// model's single observation and mutation path.
@MainActor
public struct DeclarativeTerminalConfigurationCard: View {
    private enum FocusedField: Hashable {
        case workingDirectoryPath
        case startupCommand
    }

    @State private var workingDirectoryPathDraft = ""
    @State private var shellStartupCommandDraft = ""
    @State private var fallbackSnapshot = DeclarativeTerminalConfigurationModel.Snapshot()
    @FocusState private var focusedField: FocusedField?
    @Environment(\.settingsRuntime) private var runtime

    /// Creates the card using the active ``SettingsRuntime`` environment.
    public init() {}

    /// Controls for new-surface working-directory and shell defaults.
    public var body: some View {
        SettingsCard {
            workingDirectoryPolicyRow
            SettingsCardDivider()
            workingDirectoryPathRow
            SettingsCardDivider()
            shellStartupModeRow
            SettingsCardDivider()
            shellStartupCommandRow
        }
        .task {
            configurationModel?.startObserving()
            synchronizeDrafts(currentSnapshot)
        }
        .onChange(of: configurationModel?.values) { _, newValue in
            guard let newValue else { return }
            synchronizeDrafts(newValue)
        }
        .onChange(of: focusedField) { oldValue, newValue in
            commitDraft(for: oldValue, whenMovingTo: newValue)
        }
        .onDisappear {
            // Settings can close while an AppKit-hosted text field still owns
            // focus, so no focus-change callback is guaranteed. Commit the
            // active draft before the card leaves the tree to keep file and UI
            // state converged.
            commitDraft(for: focusedField, whenMovingTo: nil)
            focusedField = nil
        }
    }

    @ViewBuilder
    private var workingDirectoryPolicyRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.newSurfaceWorkingDirectory.policy"),
            String(
                localized: "settings.terminal.newSurfaceWorkingDirectory.policy",
                defaultValue: "New Surface Working Directory"
            ),
            subtitle: String(
                localized: "settings.terminal.newSurfaceWorkingDirectory.policy.subtitle",
                defaultValue: "Choose the default directory for new local panes, tabs, splits, and workspaces. Explicit and restored startup work keeps its own directory."
            ),
            controlWidth: 220
        ) {
            Picker(
                String(
                    localized: "settings.terminal.newSurfaceWorkingDirectory.policy",
                    defaultValue: "New Surface Working Directory"
                ),
                selection: workingDirectoryPolicyBinding
            ) {
                Text(String(
                    localized: "settings.terminal.newSurfaceWorkingDirectory.policy.inheritActivePane",
                    defaultValue: "Inherit Active Pane"
                )).tag(NewSurfaceWorkingDirectoryPolicy.inheritActivePane)
                Text(String(
                    localized: "settings.terminal.newSurfaceWorkingDirectory.policy.workspaceRoot",
                    defaultValue: "Workspace Root"
                )).tag(NewSurfaceWorkingDirectoryPolicy.workspaceRoot)
                Text(String(
                    localized: "settings.terminal.newSurfaceWorkingDirectory.policy.fixedPath",
                    defaultValue: "Fixed Path"
                )).tag(NewSurfaceWorkingDirectoryPolicy.fixedPath)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("SettingsNewSurfaceWorkingDirectoryPolicyPicker")
        }
    }

    @ViewBuilder
    private var workingDirectoryPathRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.newSurfaceWorkingDirectory.path"),
            String(
                localized: "settings.terminal.newSurfaceWorkingDirectory.path",
                defaultValue: "Fixed Directory"
            ),
            subtitle: String(
                localized: "settings.terminal.newSurfaceWorkingDirectory.path.subtitle",
                defaultValue: "Used only with Fixed Path. Enter an absolute path or one beginning with ~; a missing or non-directory path falls back to the workspace root."
            ),
            controlWidth: 250
        ) {
            TextField(
                String(
                    localized: "settings.terminal.newSurfaceWorkingDirectory.path.placeholder",
                    defaultValue: "~/Projects"
                ),
                text: $workingDirectoryPathDraft
            )
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .workingDirectoryPath)
            .onSubmit {
                commitWorkingDirectoryPathDraft()
            }
            .disabled(effectiveWorkingDirectoryPolicy != .fixedPath)
            .accessibilityIdentifier("SettingsNewSurfaceWorkingDirectoryPathField")
        }
    }

    @ViewBuilder
    private var shellStartupModeRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.shellStartup.mode"),
            String(
                localized: "settings.terminal.shellStartup.mode",
                defaultValue: "Shell Startup Mode"
            ),
            subtitle: String(
                localized: "settings.terminal.shellStartup.mode.subtitle",
                defaultValue: "Select whether ordinary new local surfaces start an interactive login or non-login shell."
            ),
            controlWidth: 220
        ) {
            Picker(
                String(
                    localized: "settings.terminal.shellStartup.mode",
                    defaultValue: "Shell Startup Mode"
                ),
                selection: shellStartupModeBinding
            ) {
                Text(String(
                    localized: "settings.terminal.shellStartup.mode.login",
                    defaultValue: "Login"
                )).tag(ShellStartupMode.login)
                Text(String(
                    localized: "settings.terminal.shellStartup.mode.nonLogin",
                    defaultValue: "Non-login"
                )).tag(ShellStartupMode.nonLogin)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("SettingsShellStartupModePicker")
        }
    }

    @ViewBuilder
    private var shellStartupCommandRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.shellStartup.command"),
            String(
                localized: "settings.terminal.shellStartup.command",
                defaultValue: "Startup Command"
            ),
            subtitle: String(
                localized: "settings.terminal.shellStartup.command.subtitle",
                defaultValue: "Optional command sent after an ordinary new local shell starts. Explicit commands, remote sessions, and restored surfaces are not changed."
            ),
            controlWidth: 250
        ) {
            TextField(
                String(
                    localized: "settings.terminal.shellStartup.command.placeholder",
                    defaultValue: "mise activate zsh"
                ),
                text: $shellStartupCommandDraft
            )
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .startupCommand)
            .onSubmit {
                commitShellStartupCommandDraft()
            }
            .accessibilityIdentifier("SettingsShellStartupCommandField")
        }
    }

    private func synchronizeDrafts(_ snapshot: DeclarativeTerminalConfigurationModel.Snapshot) {
        if focusedField != .workingDirectoryPath {
            workingDirectoryPathDraft = snapshot.workingDirectoryPath
        }
        if focusedField != .startupCommand {
            shellStartupCommandDraft = snapshot.shellStartupCommand
        }
    }

    /// The effective picker value preserves the legacy fallback only while
    /// the declarative key is absent or invalid. Once the JSON key is present,
    /// the file is the sole source of truth.
    private var effectiveWorkingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy {
        currentSnapshot.effectiveWorkingDirectoryPolicy
    }

    private var workingDirectoryPolicyBinding: Binding<NewSurfaceWorkingDirectoryPolicy> {
        Binding(
            get: { effectiveWorkingDirectoryPolicy },
            set: { newValue in
                if let configurationModel {
                    configurationModel.setWorkingDirectoryPolicy(newValue)
                } else {
                    fallbackSnapshot.workingDirectoryPolicy = newValue
                }
            }
        )
    }

    private var shellStartupModeBinding: Binding<ShellStartupMode> {
        Binding(
            get: { currentSnapshot.shellStartupMode },
            set: { newValue in
                if let configurationModel {
                    configurationModel.setShellStartupMode(newValue)
                } else {
                    fallbackSnapshot.shellStartupMode = newValue
                }
            }
        )
    }

    private var configurationModel: DeclarativeTerminalConfigurationModel? {
        runtime?.declarativeTerminalConfigurationModel
    }

    private var currentSnapshot: DeclarativeTerminalConfigurationModel.Snapshot {
        configurationModel?.values ?? fallbackSnapshot
    }

    private func commitDraft(for oldValue: FocusedField?, whenMovingTo newValue: FocusedField?) {
        guard oldValue != newValue else { return }
        switch oldValue {
        case .workingDirectoryPath:
            commitWorkingDirectoryPathDraft()
        case .startupCommand:
            commitShellStartupCommandDraft()
        case nil:
            break
        }
    }

    /// Persists and then re-reads the committed value. The explicit
    /// reconciliation keeps a rejected write from leaving the unfocused draft
    /// ahead of the file; the runtime-owned model performs the write and
    /// presence-preserving reconciliation.
    private func commitWorkingDirectoryPathDraft() {
        let draft = workingDirectoryPathDraft
        guard let configurationModel else {
            workingDirectoryPathDraft = currentSnapshot.workingDirectoryPath
            return
        }
        configurationModel.setWorkingDirectoryPath(draft)
    }

    /// Persists and reconciles the shell-command draft through the same actor
    /// and error surface as every other JSON-backed setting.
    private func commitShellStartupCommandDraft() {
        let draft = shellStartupCommandDraft
        guard let configurationModel else {
            shellStartupCommandDraft = currentSnapshot.shellStartupCommand
            return
        }
        configurationModel.setShellStartupCommand(draft)
    }
}
