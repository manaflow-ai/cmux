import CmuxSettings
import CmuxFoundation
import SwiftUI

/// Settings-card controls for the declarative defaults used by new local
/// terminal surfaces.
///
/// The controls deliberately use ``LiveSetting`` rather than a second draft
/// store. Reads therefore follow the JSON file watcher and writes go through
/// the same `cmux.json` actor used by file edits, so a dotfiles change and a
/// Settings edit converge on one value.
@MainActor
public struct DeclarativeTerminalConfigurationCard: View {
    private enum FocusedField: Hashable {
        case workingDirectoryPath
        case startupCommand
    }

    @LiveSetting(\.terminal.newSurfaceWorkingDirectoryPolicy)
    private var workingDirectoryPolicy
    @LiveSetting(\.terminal.newSurfaceWorkingDirectoryPath)
    private var workingDirectoryPath
    @LiveSetting(\.terminal.shellStartupMode)
    private var shellStartupMode
    @LiveSetting(\.terminal.shellStartupCommand)
    private var shellStartupCommand

    @State private var workingDirectoryPathDraft = ""
    @State private var shellStartupCommandDraft = ""
    @State private var commitTasks = MainActorTaskStore<String>()
    /// `@LiveSetting` intentionally applies the JSON key's declared default
    /// when a path is absent. The working-directory policy still has a legacy
    /// UserDefaults fallback, so keep presence and the fallback separate from
    /// the defaulting binding. This lets a dotfiles edit that removes or
    /// invalidates the new key immediately converge the UI with runtime.
    @State private var workingDirectoryPolicyIfPresent: NewSurfaceWorkingDirectoryPolicy?
    @State private var legacyWorkingDirectoryPolicy = NewSurfaceWorkingDirectoryPolicy.inheritActivePane
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
            synchronizeDrafts()
        }
        .task {
            await observeWorkingDirectoryPolicy()
        }
        .onChange(of: workingDirectoryPath) { _, newValue in
            guard focusedField != .workingDirectoryPath else { return }
            workingDirectoryPathDraft = newValue
        }
        .onChange(of: shellStartupCommand) { _, newValue in
            guard focusedField != .startupCommand else { return }
            shellStartupCommandDraft = newValue
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
                selection: $shellStartupMode
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

    private func synchronizeDrafts() {
        if focusedField != .workingDirectoryPath {
            workingDirectoryPathDraft = workingDirectoryPath
        }
        if focusedField != .startupCommand {
            shellStartupCommandDraft = shellStartupCommand
        }
    }

    /// The effective picker value preserves the legacy fallback only while
    /// the declarative key is absent or invalid. Once the JSON key is present,
    /// the file is the sole source of truth.
    private var effectiveWorkingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy {
        workingDirectoryPolicyIfPresent ?? legacyWorkingDirectoryPolicy
    }

    private var workingDirectoryPolicyBinding: Binding<NewSurfaceWorkingDirectoryPolicy> {
        Binding(
            get: { effectiveWorkingDirectoryPolicy },
            set: { newValue in
                workingDirectoryPolicy = newValue
            }
        )
    }

    /// Observes both sides of the legacy compatibility boundary. Separate
    /// streams are event-driven (no polling/sleeps), and the JSON presence
    /// stream means an external dotfiles edit cannot leave the picker showing
    /// a value that runtime no longer uses.
    private func observeWorkingDirectoryPolicy() async {
        guard let runtime else { return }
        let catalog = SettingCatalog()
        let policyKey = catalog.terminal.newSurfaceWorkingDirectoryPolicy
        let legacyKey = catalog.app.workspaceInheritWorkingDirectory

        workingDirectoryPolicyIfPresent = await runtime.jsonStore.valueIfPresent(for: policyKey)
        legacyWorkingDirectoryPolicy = (await runtime.userDefaultsStore.value(for: legacyKey))
            ? .inheritActivePane
            : .workspaceRoot

        async let jsonObservation: Void = observeJSONWorkingDirectoryPolicy(
            store: runtime.jsonStore,
            key: policyKey
        )
        async let legacyObservation: Void = observeLegacyWorkingDirectoryPolicy(
            store: runtime.userDefaultsStore,
            key: legacyKey
        )
        _ = await (jsonObservation, legacyObservation)
    }

    private func observeJSONWorkingDirectoryPolicy(
        store: JSONConfigStore,
        key: JSONKey<NewSurfaceWorkingDirectoryPolicy>
    ) async {
        for await value in store.valuesIfPresent(for: key) {
            if Task.isCancelled { return }
            workingDirectoryPolicyIfPresent = value
        }
    }

    private func observeLegacyWorkingDirectoryPolicy(
        store: UserDefaultsSettingsStore,
        key: DefaultsKey<Bool>
    ) async {
        for await value in store.values(for: key) {
            if Task.isCancelled { return }
            legacyWorkingDirectoryPolicy = value
                ? .inheritActivePane
                : .workspaceRoot
        }
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
    /// ahead of the file, while the live-setting stream remains the source for
    /// successful writes and external dotfiles edits.
    private func commitWorkingDirectoryPathDraft() {
        let draft = workingDirectoryPathDraft
        guard let runtime else {
            workingDirectoryPathDraft = workingDirectoryPath
            return
        }
        let key = SettingCatalog().terminal.newSurfaceWorkingDirectoryPath
        commitTasks.replaceOnMainActor("workingDirectoryPath") {
            do {
                try await runtime.jsonStore.set(draft, for: key)
            } catch {
                runtime.errorLog.recordSaveFailure(keyID: key.id)
            }
            guard !Task.isCancelled else { return }
            let committed = await runtime.jsonStore.value(for: key)
            if !Task.isCancelled, focusedField != .workingDirectoryPath {
                workingDirectoryPathDraft = committed
            }
        }
    }

    /// Persists and reconciles the shell-command draft through the same actor
    /// and error surface as every other JSON-backed setting.
    private func commitShellStartupCommandDraft() {
        let draft = shellStartupCommandDraft
        guard let runtime else {
            shellStartupCommandDraft = shellStartupCommand
            return
        }
        let key = SettingCatalog().terminal.shellStartupCommand
        commitTasks.replaceOnMainActor("shellStartupCommand") {
            do {
                try await runtime.jsonStore.set(draft, for: key)
            } catch {
                runtime.errorLog.recordSaveFailure(keyID: key.id)
            }
            guard !Task.isCancelled else { return }
            let committed = await runtime.jsonStore.value(for: key)
            if !Task.isCancelled, focusedField != .startupCommand {
                shellStartupCommandDraft = committed
            }
        }
    }
}
