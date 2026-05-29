import CmuxSettings
import SwiftUI

/// **Terminal** section — mirrors the legacy in-app section
/// row-for-row: scroll bar, text-box max lines, copy on selection,
/// resume agent sessions, agent hibernation enable + idle seconds +
/// max live terminals, plus the JSON-backed Resume Commands editor.
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
        Group {
            SettingsSectionHeader(String(localized: "settings.section.terminal", defaultValue: "Terminal"))
            mainCard
            resumeCommandsCard
        }
        .task { await observeResumeCommands() }
        .onDisappear { resumeStreamTask?.cancel() }
    }

    @ViewBuilder
    private var mainCard: some View {
        let scrollBar = DefaultsValueModel(store: defaultsStore, key: catalog.terminal.showScrollBar)
        let textBoxLines = DefaultsValueModel(store: defaultsStore, key: catalog.terminal.textBoxMaxLines)
        let copyOnSelect = DefaultsValueModel(store: defaultsStore, key: catalog.terminal.copyOnSelect)
        let autoResume = DefaultsValueModel(store: defaultsStore, key: catalog.terminal.autoResumeAgentSessions)
        let hibernation = DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationEnabled)
        let idleSeconds = DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationIdleSeconds)
        let maxLive = DefaultsValueModel(store: defaultsStore, key: catalog.terminal.agentHibernationMaxLiveTerminals)

        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("terminal.showScrollBar"),
                String(localized: "settings.terminal.scrollBar", defaultValue: "Show Terminal Scroll Bar"),
                subtitle: scrollBar.current
                    ? String(localized: "settings.terminal.scrollBar.subtitleOn", defaultValue: "Shows the right-edge terminal scroll bar in shell scrollback. cmux hides it automatically for alternate-screen style TUI surfaces and you can also disable it per workspace.")
                    : String(localized: "settings.terminal.scrollBar.subtitleOff", defaultValue: "Hides the right-edge terminal scroll bar everywhere. Changes apply immediately and persist across relaunches.")
            ) {
                Toggle("", isOn: Binding(get: { scrollBar.current }, set: { scrollBar.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalScrollBarToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.textBoxMaxLines"),
                String(localized: "settings.terminal.textBoxMaxLines", defaultValue: "TextBox Max Lines"),
                subtitle: String(localized: "settings.terminal.textBoxMaxLines.subtitle", defaultValue: "Limits how tall the rich terminal input can grow before it scrolls."),
                controlWidth: 220
            ) {
                Stepper(
                    value: Binding(get: { textBoxLines.current }, set: { textBoxLines.set($0) }),
                    in: 1...20
                ) {
                    Text(verbatim: "\(textBoxLines.current)")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTerminalTextBoxMaxLinesStepper")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.copyOnSelect"),
                String(localized: "settings.terminal.copyOnSelect", defaultValue: "Copy on Selection"),
                subtitle: copyOnSelect.current
                    ? String(localized: "settings.terminal.copyOnSelect.subtitleOn", defaultValue: "Selected terminal text is copied to the system clipboard when the selection is committed.")
                    : String(localized: "settings.terminal.copyOnSelect.subtitleOff", defaultValue: "Terminal selections do not replace the system clipboard. Use Cmd+C to copy manually.")
            ) {
                Toggle("", isOn: Binding(get: { copyOnSelect.current }, set: { copyOnSelect.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalCopyOnSelectToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.autoResumeAgentSessions"),
                String(localized: "settings.terminal.agentAutoResume", defaultValue: "Resume Agent Sessions on Reopen"),
                subtitle: autoResume.current
                    ? String(localized: "settings.terminal.agentAutoResume.subtitleOn", defaultValue: "When cmux reopens after quit, restored agent terminals automatically run their resume command.")
                    : String(localized: "settings.terminal.agentAutoResume.subtitleOff", defaultValue: "When cmux reopens after quit, restored agent terminals stay idle until you resume them manually.")
            ) {
                Toggle("", isOn: Binding(get: { autoResume.current }, set: { autoResume.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalAgentAutoResumeToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.agentHibernation.enabled"),
                String(localized: "settings.terminal.agentHibernation", defaultValue: "Agent Hibernation"),
                subtitle: hibernation.current
                    ? String(localized: "settings.terminal.agentHibernation.subtitleOn", defaultValue: "Idle background agent terminals can be suspended when the live-terminal limit is exceeded.")
                    : String(localized: "settings.terminal.agentHibernation.subtitleOff", defaultValue: "Agent terminals stay live until you close them or quit cmux.")
            ) {
                Toggle("", isOn: Binding(get: { hibernation.current }, set: { hibernation.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsTerminalAgentHibernationToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.agentHibernation.idleSeconds"),
                String(localized: "settings.terminal.agentHibernation.idleSeconds", defaultValue: "Hibernate After Idle Seconds"),
                subtitle: String(localized: "settings.terminal.agentHibernation.idleSeconds.subtitle", defaultValue: "A terminal must have no output and report an idle agent lifecycle for this long before it can be suspended."),
                controlWidth: 140
            ) {
                Stepper(
                    "\(Int(idleSeconds.current))",
                    value: Binding(get: { idleSeconds.current }, set: { idleSeconds.set($0) }),
                    in: 5...604_800,
                    step: 60
                )
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTerminalAgentHibernationIdleSecondsStepper")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("terminal.agentHibernation.maxLiveTerminals"),
                String(localized: "settings.terminal.agentHibernation.maxLiveTerminals", defaultValue: "Max Live Agent Terminals"),
                subtitle: String(localized: "settings.terminal.agentHibernation.maxLiveTerminals.subtitle", defaultValue: "Visible terminals stay live. Extra idle background agent terminals hibernate oldest first."),
                controlWidth: 120
            ) {
                Stepper(
                    "\(maxLive.current)",
                    value: Binding(get: { maxLive.current }, set: { maxLive.set($0) }),
                    in: 1...256,
                    step: 1
                )
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTerminalAgentHibernationMaxLiveStepper")
            }
        }
    }

    @ViewBuilder
    private var resumeCommandsCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("terminal.resumeCommands"),
                String(localized: "settings.terminal.resumeCommands", defaultValue: "Resume Commands"),
                subtitle: String(localized: "settings.terminal.resumeCommands.subtitle", defaultValue: "Newline-delimited commands cmux runs when a terminal resumes. Persisted in cmux.json so the same list applies to every workspace.")
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
                    Button(String(localized: "settings.terminal.resumeCommands.apply", defaultValue: "Apply")) {
                        commitResumeDraft()
                    }
                    .disabled(resumeDraft == resumeCommands.joined(separator: "\n"))
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
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
}
