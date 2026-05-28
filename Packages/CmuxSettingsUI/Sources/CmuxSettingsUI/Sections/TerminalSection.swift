import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Terminal** section.
///
/// Hosts scrollbar visibility, copy-on-select, agent session resume /
/// hibernation, the multi-line text-box maximum height, and the JSON
/// resume-command list. Mirrors the legacy in-app section.
@MainActor
public struct TerminalSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog

    @State private var resumeCommands: [String] = []
    @State private var resumeStreamTask: Task<Void, Never>?
    @State private var resumeDraft: String = ""

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog
    ) {
        self.defaultsStore = defaultsStore
        self.jsonStore = jsonStore
        self.catalog = catalog
    }

    public var body: some View {
        Form {
            Section("Display") {
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.showScrollBar),
                    title: "Show terminal scroll bar"
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.copyOnSelect),
                    title: "Copy on selection",
                    subtitle: "Selecting text in a terminal copies it to the clipboard automatically."
                )
                SettingsStepperRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.textBoxMaxLines),
                    title: "Text box max lines",
                    range: 1...20
                )
            }
            Section("Agents") {
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.autoResumeAgentSessions),
                    title: "Resume agent sessions on reopen",
                    subtitle: "When cmux relaunches, restore Claude / Codex / opencode sessions automatically."
                )
                SettingsToggleRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationEnabled),
                    title: "Hibernate idle agents",
                    subtitle: "Suspend background agent terminals after a period of inactivity."
                )
                SettingsDoubleStepperRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationIdleSeconds),
                    title: "Hibernation idle threshold",
                    range: 30...3_600,
                    step: 30,
                    format: { value in "\(Int(value))s" }
                )
                SettingsStepperRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationMaxLiveTerminals),
                    title: "Max live agent terminals",
                    range: 1...256
                )
            }
            Section("Resume Commands") {
                Text("Newline-delimited list of commands cmux will run when a terminal is resumed. Persisted in cmux.json so the same list applies to every workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $resumeDraft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90, maxHeight: 160)
                    .border(Color(nsColor: .separatorColor))
                HStack {
                    Spacer()
                    Button("Apply") {
                        commitResumeDraft()
                    }
                    .disabled(resumeDraft == resumeJoined(resumeCommands))
                }
            }
        }
        .formStyle(.grouped)
        .task { await observeResumeCommands() }
        .onDisappear { resumeStreamTask?.cancel() }
    }

    private func observeResumeCommands() async {
        resumeStreamTask?.cancel()
        let task = Task {
            for await commands in jsonStore.values(for: catalog.terminal.resumeCommands) {
                if Task.isCancelled { break }
                if commands != resumeCommands {
                    resumeCommands = commands
                    let joined = resumeJoined(commands)
                    if resumeDraft != joined {
                        resumeDraft = joined
                    }
                }
            }
        }
        resumeStreamTask = task
        await task.value
    }

    private func commitResumeDraft() {
        let updated = resumeDraft
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Task {
            do {
                try await jsonStore.set(updated, for: catalog.terminal.resumeCommands)
            } catch {
                // Surfaced through SettingsErrorLog if one is injected
                // higher in the view tree via the standard alert path.
            }
        }
    }

    private func resumeJoined(_ commands: [String]) -> String {
        commands.joined(separator: "\n")
    }
}
