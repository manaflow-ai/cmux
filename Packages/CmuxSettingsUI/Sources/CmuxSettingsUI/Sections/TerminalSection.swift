import CmuxSettings
import SwiftUI

/// **Terminal** section rendered as a stack of `SettingsCard`s.
@MainActor
public struct TerminalSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog

    @State private var resumeCommands: [String] = []
    @State private var resumeDraft: String = ""
    @State private var resumeStreamTask: Task<Void, Never>?

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
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("Terminal")
            SettingsCard {
                toggleRow(
                    title: "Show Terminal Scroll Bar",
                    subtitle: nil,
                    json: "terminal.showScrollBar",
                    key: catalog.terminal.showScrollBar
                )
                SettingsCardDivider()
                toggleRow(
                    title: "Copy on Selection",
                    subtitle: "Selecting text in a terminal copies it to the clipboard automatically.",
                    json: "terminal.copyOnSelect",
                    key: catalog.terminal.copyOnSelect
                )
                SettingsCardDivider()
                intStepperRow(
                    title: "Text Box Max Lines",
                    subtitle: "Limits how tall the rich terminal input can grow before it scrolls.",
                    json: "terminal.textBoxMaxLines",
                    key: catalog.terminal.textBoxMaxLines,
                    range: 1...20
                )
            }

            SettingsSectionHeader("Agents")
            SettingsCard {
                toggleRow(
                    title: "Resume Agent Sessions on Reopen",
                    subtitle: "When cmux relaunches, restore Claude / Codex / opencode sessions automatically.",
                    json: "terminal.autoResumeAgentSessions",
                    key: catalog.terminal.autoResumeAgentSessions
                )
                SettingsCardDivider()
                toggleRow(
                    title: "Hibernate Idle Agents",
                    subtitle: "Suspend background agent terminals after a period of inactivity.",
                    json: "terminal.agentHibernation.enabled",
                    key: catalog.terminal.agentHibernationEnabled
                )
                SettingsCardDivider()
                doubleStepperRow(
                    title: "Hibernation Idle Threshold",
                    subtitle: "Seconds of inactivity before hibernation kicks in.",
                    json: "terminal.agentHibernation.idleSeconds",
                    key: catalog.terminal.agentHibernationIdleSeconds,
                    range: 30...3_600,
                    step: 30,
                    format: { "\(Int($0))s" }
                )
                SettingsCardDivider()
                intStepperRow(
                    title: "Max Live Agent Terminals",
                    subtitle: nil,
                    json: "terminal.agentHibernation.maxLiveTerminals",
                    key: catalog.terminal.agentHibernationMaxLiveTerminals,
                    range: 1...256
                )
            }

            SettingsSectionHeader("Resume Commands")
            SettingsCard {
                resumeCommandsRow
            }
        }
        .task { await observeResumeCommands() }
        .onDisappear { resumeStreamTask?.cancel() }
    }

    @ViewBuilder
    private var resumeCommandsRow: some View {
        SettingsCardRow(
            configurationReview: .json("terminal.resumeCommands"),
            "Resume Commands",
            subtitle: "Newline-delimited list of commands cmux runs when a terminal is resumed."
        ) {
            EmptyView()
        }
        SettingsCardDivider()
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $resumeDraft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 160)
                .border(Color(nsColor: .separatorColor))
            HStack {
                Spacer()
                Button("Apply") { commitResumeDraft() }
                    .disabled(resumeDraft == resumeCommands.joined(separator: "\n"))
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func observeResumeCommands() async {
        resumeStreamTask?.cancel()
        let task = Task {
            for await commands in jsonStore.values(for: catalog.terminal.resumeCommands) {
                if Task.isCancelled { break }
                if commands != resumeCommands {
                    resumeCommands = commands
                    let joined = commands.joined(separator: "\n")
                    if resumeDraft != joined { resumeDraft = joined }
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
            try? await jsonStore.set(updated, for: catalog.terminal.resumeCommands)
        }
    }

    @ViewBuilder
    private func toggleRow(title: String, subtitle: String?, json: String, key: DefaultsKey<Bool>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle) {
            Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                .labelsHidden()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func intStepperRow(title: String, subtitle: String?, json: String, key: DefaultsKey<Int>, range: ClosedRange<Int>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle, controlWidth: 120) {
            Stepper(value: Binding(get: { model.current }, set: { model.set($0) }), in: range) {
                Text("\(model.current)").monospacedDigit()
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func doubleStepperRow(title: String, subtitle: String?, json: String, key: DefaultsKey<Double>, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, subtitle: subtitle, controlWidth: 140) {
            Stepper(value: Binding(get: { model.current }, set: { model.set($0) }), in: range, step: step) {
                Text(format(model.current)).monospacedDigit()
            }
            .controlSize(.small)
        }
    }
}
