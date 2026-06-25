import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Automation** section — mirrors the legacy in-app section
/// row-for-row: Socket Control (mode picker, password subrow when
/// .password, warnings, overrides note), then separate cards for
/// Claude Code Integration, Claude Binary Path, Ripgrep Binary Path,
/// Suppress Subagent Notifications, Cursor Integration, Gemini
/// Integration, and Port Base / Port Range Size.
@MainActor
public struct AutomationSection: View {
    private let catalog: SettingCatalog

    @State private var socketPasswordModel: SecretValueModel
    @State private var modeModel: DefaultsValueModel<SocketControlMode>
    @State private var claudeCodeModel: DefaultsValueModel<Bool>
    @State private var codexModel: DefaultsValueModel<Bool>
    @State private var claudePathModel: DefaultsValueModel<String>
    @State private var autoNamingModel: DefaultsValueModel<Bool>
    @State private var autoNamingAgentModel: DefaultsValueModel<String>
    @State private var autoNamingStatusModel: DefaultsValueModel<String>
    @State private var ripgrepPathModel: DefaultsValueModel<String>
    @State private var suppressSubagentModel: DefaultsValueModel<Bool>
    @State private var ampModel: DefaultsValueModel<Bool>
    @State private var cursorModel: DefaultsValueModel<Bool>
    @State private var geminiModel: DefaultsValueModel<Bool>
    @State private var kiroModel: DefaultsValueModel<Bool>
    @State private var kiroLevelModel: DefaultsValueModel<String>
    @State private var portBaseModel: DefaultsValueModel<Int>
    @State private var portRangeModel: DefaultsValueModel<Int>
    @State private var socketPasswordDraft: String = ""
    @State private var socketPasswordStatus: SocketPasswordStatus?
    @State private var showOpenAccessConfirmation: Bool = false
    @State private var pendingOpenAccessMode: SocketControlMode?
    @State private var modeBeforePendingOpenAccess: SocketControlMode?

    private struct SocketPasswordStatus: Equatable {
        let message: String
        let isError: Bool
    }

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        secretStore: SecretFileStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog
    ) {
        self.catalog = catalog
        _socketPasswordModel = State(initialValue: SecretValueModel(
            store: secretStore,
            key: catalog.automation.socketPassword,
            errorLog: errorLog
        ))
        _modeModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.socketControlMode))
        _claudeCodeModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.claudeCodeHooksEnabled))
        _codexModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.codexHooksEnabled))
        _claudePathModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.claudeCodeCustomClaudePath))
        _autoNamingModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.workspaceAutoNaming))
        _autoNamingAgentModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.autoNamingAgent))
        // Internal status (not a user setting), observed reactively via an
        // inline key so a failure reported mid-session updates the line live.
        _autoNamingStatusModel = State(initialValue: DefaultsValueModel(
            store: defaultsStore,
            key: DefaultsKey<String>(
                id: "automation.autoNamingLastStatus",
                defaultValue: "",
                userDefaultsKey: AutoNamingStatusStore.userDefaultsKey
            )
        ))
        _ripgrepPathModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.ripgrepCustomBinaryPath))
        _suppressSubagentModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.suppressSubagentNotifications))
        _ampModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.ampHooksEnabled))
        _cursorModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.cursorHooksEnabled))
        _geminiModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.geminiHooksEnabled))
        _kiroModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.kiroHooksEnabled))
        _kiroLevelModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.kiroNotificationLevel))
        _portBaseModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.portBase))
        _portRangeModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.portRange))
    }

    private static let columnWidth: CGFloat = 196

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.automation", defaultValue: "Automation"), section: .automation)

            socketControlCard
            claudeCodeCard
            codexCard
            claudePathCard
            autoNamingCard
            ripgrepPathCard
            suppressSubagentCard
            ampCard
            cursorCard
            geminiCard
            kiroCard
            portCard
        }
        .confirmationDialog(
            String(localized: "settings.automation.openAccess.dialog.title", defaultValue: "Enable full open access?"),
            isPresented: $showOpenAccessConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "settings.automation.openAccess.dialog.confirm", defaultValue: "Enable Full Open Access"),
                role: .destructive
            ) {
                if let pending = pendingOpenAccessMode {
                    modeModel.set(pending)
                }
                pendingOpenAccessMode = nil
                modeBeforePendingOpenAccess = nil
            }
            Button(
                String(localized: "settings.automation.openAccess.dialog.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {
                pendingOpenAccessMode = nil
                modeBeforePendingOpenAccess = nil
            }
        } message: {
            Text(String(
                localized: "settings.automation.openAccess.dialog.message",
                defaultValue: "This disables ancestry and password checks and opens the socket to all local users. Only enable when you understand the risk."
            ))
        }.task { startSettingsObservation([socketPasswordModel, modeModel, claudeCodeModel, codexModel, claudePathModel, autoNamingModel, autoNamingAgentModel, autoNamingStatusModel, ripgrepPathModel, suppressSubagentModel, ampModel, cursorModel, geminiModel, kiroModel, kiroLevelModel, portBaseModel, portRangeModel]) }
    }

    @ViewBuilder
    private var socketControlCard: some View {
        let isPassword = modeModel.current == .password
        let isAllowAll = modeModel.current == .allowAll
        let hasPassword = !socketPasswordModel.current.isEmpty

        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.socketControlMode"),
                String(localized: "settings.automation.socketMode", defaultValue: "Socket Control Mode"),
                subtitle: modeModel.current.description,
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(
                    get: { modeModel.current },
                    set: { newValue in
                        if newValue == .allowAll && modeModel.current != .allowAll {
                            modeBeforePendingOpenAccess = modeModel.current
                            pendingOpenAccessMode = newValue
                            showOpenAccessConfirmation = true
                            return
                        }
                        modeModel.set(newValue)
                        if newValue != .password {
                            socketPasswordStatus = nil
                        }
                    }
                )) {
                    ForEach(SocketControlMode.uiCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("AutomationSocketModePicker")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.socketMode.note", defaultValue: "Controls access to the local Unix socket for programmatic control. Choose a mode that matches your threat model."))

            if isPassword {
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .json("automation.socketPassword"),
                    String(localized: "settings.automation.socketPassword", defaultValue: "Socket Password"),
                    subtitle: hasPassword
                        ? String(localized: "settings.automation.socketPassword.subtitleSet", defaultValue: "Stored in Application Support.")
                        : String(localized: "settings.automation.socketPassword.subtitleUnset", defaultValue: "No password set. External clients will be blocked until one is configured.")
                ) {
                    HStack(spacing: 8) {
                        SecureField(
                            String(localized: "settings.automation.socketPassword.placeholder", defaultValue: "Password"),
                            text: $socketPasswordDraft
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        Button(
                            hasPassword
                                ? String(localized: "settings.automation.socketPassword.change", defaultValue: "Change")
                                : String(localized: "settings.automation.socketPassword.set", defaultValue: "Set")
                        ) {
                            saveSocketPassword()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasPassword {
                            Button(String(localized: "settings.automation.socketPassword.clear", defaultValue: "Clear")) {
                                clearSocketPassword()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                if let status = socketPasswordStatus {
                    Text(status.message)
                        .cmuxFont(.caption)
                        .foregroundStyle(status.isError ? Color.red : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }

            if isAllowAll {
                SettingsCardDivider()
                Text(String(localized: "settings.automation.openAccessWarning", defaultValue: "Warning: Full open access makes the control socket world-readable/writable on this Mac and disables auth checks. Use only for local debugging."))
                    .cmuxFont(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            SettingsCardNote(String(localized: "settings.automation.socketOverrides.note", defaultValue: "Overrides: CMUX_SOCKET_ENABLE, CMUX_SOCKET_MODE, and CMUX_SOCKET_PATH (set CMUX_ALLOW_SOCKET_OVERRIDE=1 for stable/nightly builds)."))
        }
    }

    @ViewBuilder
    private var claudeCodeCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.claudeCodeIntegration"),
                String(localized: "settings.automation.claudeCode", defaultValue: "Claude Code Integration"),
                subtitle: claudeCodeModel.current
                    ? String(localized: "settings.automation.claudeCode.subtitleOn", defaultValue: "Sidebar shows Claude session status and notifications.")
                    : String(localized: "settings.automation.claudeCode.subtitleOff", defaultValue: "Claude Code runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { claudeCodeModel.current }, set: { claudeCodeModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsClaudeCodeHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.claudeCode.note", defaultValue: "When enabled, cmux wraps the claude command to inject session tracking and notification hooks. Disable if you prefer to manage Claude Code hooks yourself."))
        }
    }

    @ViewBuilder
    private var codexCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.codexIntegration"),
                String(localized: "settings.automation.codex", defaultValue: "Codex Integration"),
                subtitle: codexModel.current
                    ? String(localized: "settings.automation.codex.subtitleOn", defaultValue: "Sidebar shows Codex session status and notifications.")
                    : String(localized: "settings.automation.codex.subtitleOff", defaultValue: "Codex runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { codexModel.current }, set: { codexModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsCodexHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.codex.note", defaultValue: "When enabled, cmux wraps the codex command to inject session tracking and notification hooks. Disable if you prefer to manage Codex hooks yourself. cmux still tracks live Codex sessions it can observe even when this is off."))
        }
    }

    @ViewBuilder
    private var claudePathCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.claudeBinaryPath"),
                String(localized: "settings.automation.claudeCode.customPath", defaultValue: "Claude Binary Path"),
                subtitle: String(localized: "settings.automation.claudeCode.customPath.subtitle", defaultValue: "Custom path to the claude binary. Leave empty to use PATH.")
            ) {
                TextField(
                    String(localized: "settings.automation.claudeCode.customPath.placeholder", defaultValue: "e.g. /usr/local/bin/claude"),
                    text: Binding(get: { claudePathModel.current }, set: { claudePathModel.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
        }
    }

    @ViewBuilder
    private var autoNamingCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.workspaceAutoNaming"),
                String(localized: "settings.automation.workspaceAutoNaming", defaultValue: "Workspace Auto-Naming"),
                subtitle: autoNamingModel.current
                    ? String(localized: "settings.automation.workspaceAutoNaming.subtitleOn", defaultValue: "Workspaces and tabs are named from agent conversations.")
                    : String(localized: "settings.automation.workspaceAutoNaming.subtitleOff", defaultValue: "Workspace and tab names are never generated.")
            ) {
                Toggle("", isOn: Binding(get: { autoNamingModel.current }, set: { autoNamingModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsWorkspaceAutoNamingToggle")
            }
            if autoNamingModel.current {
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .json("automation.autoNamingAgent"),
                    String(localized: "settings.automation.autoNamingAgent", defaultValue: "Naming Agent"),
                    subtitle: AutoNamingAgentDisplay.selectionSubtitle(forSlug: autoNamingAgentModel.current),
                    controlWidth: Self.columnWidth
                ) {
                    Picker("", selection: Binding(get: { autoNamingAgentModel.current }, set: { autoNamingAgentModel.set($0) })) {
                        Text(String(localized: "settings.automation.autoNamingAgent.auto", defaultValue: "Automatic"))
                            .tag(AutoNamingAgentCatalog.autoSlug)
                        Section(String(localized: "settings.automation.autoNamingAgent.section.supported", defaultValue: "Supported")) {
                            ForEach(AutoNamingAgentCatalog.supportedAgents, id: \.slug) { agent in
                                Text(agent.displayName).tag(agent.slug)
                            }
                        }
                        Section(String(localized: "settings.automation.autoNamingAgent.section.other", defaultValue: "Other agents")) {
                            ForEach(AutoNamingAgentCatalog.otherAgents, id: \.slug) { agent in
                                Text(agent.displayName).tag(agent.slug)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("SettingsAutoNamingAgentPicker")
                }
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.workspaceAutoNaming.note", defaultValue: "When enabled, cmux summarizes supported agent sessions into short workspace and tab names using each agent's own binary, refreshed as the topic shifts. Manual renames always win and stop auto-naming for that workspace or tab. Uses your agent account for the short summarization calls."))
            if autoNamingModel.current,
               !claudeCodeModel.current,
               autoNamingAgentModel.current == AutoNamingAgentCatalog.autoSlug || autoNamingAgentModel.current == "claude" {
                autoNamingFootnote(String(localized: "settings.automation.workspaceAutoNaming.hooksOffWarning", defaultValue: "Claude Code Integration is off, so Claude sessions will not be auto-named. Other supported agents still name when their cmux hooks are installed."))
            }
            if autoNamingModel.current, let status = currentAutoNamingStatus {
                autoNamingFootnote(AutoNamingAgentDisplay.statusMessage(status))
            }
        }
    }

    @ViewBuilder
    private func autoNamingFootnote(_ text: String) -> some View {
        Text(text)
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
    }

    private var currentAutoNamingStatus: AutoNamingStatus? {
        guard !autoNamingStatusModel.current.isEmpty,
              let data = autoNamingStatusModel.current.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AutoNamingStatus.self, from: data)
    }

    @ViewBuilder
    private var ripgrepPathCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.ripgrepBinaryPath"),
                String(localized: "settings.automation.ripgrep.customPath", defaultValue: "Ripgrep Binary Path"),
                subtitle: String(localized: "settings.automation.ripgrep.customPath.subtitle", defaultValue: "Custom path to the rg binary used by Find. Leave empty to use common install locations and PATH.")
            ) {
                TextField(
                    String(localized: "settings.automation.ripgrep.customPath.placeholder", defaultValue: "e.g. /etc/profiles/per-user/you/bin/rg"),
                    text: Binding(get: { ripgrepPathModel.current }, set: { ripgrepPathModel.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
        }
    }

    @ViewBuilder
    private var suppressSubagentCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.suppressSubagentNotifications"),
                String(localized: "settings.automation.suppressSubagentNotifications", defaultValue: "Suppress Subagent Notifications"),
                subtitle: suppressSubagentModel.current
                    ? String(localized: "settings.automation.suppressSubagentNotifications.subtitleOn", defaultValue: "Child agent completions stay in Feed without notifications.")
                    : String(localized: "settings.automation.suppressSubagentNotifications.subtitleOff", defaultValue: "Child agent completions notify like top-level agents.")
            ) {
                Toggle("", isOn: Binding(get: { suppressSubagentModel.current }, set: { suppressSubagentModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsSuppressSubagentNotificationsToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.suppressSubagentNotifications.note", defaultValue: "Uses process ancestry from hook processes. Disable if nested Codex or Claude sessions should trigger completion notifications."))
        }
    }

    @ViewBuilder
    private var ampCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.ampIntegration"),
                String(localized: "settings.automation.amp", defaultValue: "Amp Integration"),
                subtitle: ampModel.current
                    ? String(localized: "settings.automation.amp.subtitleOn", defaultValue: "Sidebar shows Amp agent status and notifications.")
                    : String(localized: "settings.automation.amp.subtitleOff", defaultValue: "Amp runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { ampModel.current }, set: { ampModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsAmpHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.amp.note", defaultValue: "Hooks must be installed with `cmux hooks amp install`. They no-op outside cmux terminals. When disabled, the installed Amp plugin stays inactive without needing to be removed."))
        }
    }

    @ViewBuilder
    private var cursorCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.cursorIntegration"),
                String(localized: "settings.automation.cursor", defaultValue: "Cursor Integration"),
                subtitle: cursorModel.current
                    ? String(localized: "settings.automation.cursor.subtitleOn", defaultValue: "Sidebar shows Cursor agent status and notifications.")
                    : String(localized: "settings.automation.cursor.subtitleOff", defaultValue: "Cursor runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { cursorModel.current }, set: { cursorModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsCursorHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.cursor.note", defaultValue: "Hooks must be installed with `cmux hooks cursor install`. They no-op outside cmux terminals."))
        }
    }

    @ViewBuilder
    private var geminiCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.geminiIntegration"),
                String(localized: "settings.automation.gemini", defaultValue: "Gemini CLI Integration"),
                subtitle: geminiModel.current
                    ? String(localized: "settings.automation.gemini.subtitleOn", defaultValue: "Sidebar shows Gemini session status and notifications.")
                    : String(localized: "settings.automation.gemini.subtitleOff", defaultValue: "Gemini runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { geminiModel.current }, set: { geminiModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsGeminiHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.gemini.note", defaultValue: "Hooks must be installed with `cmux hooks gemini install`. They no-op outside cmux terminals."))
        }
    }

    @ViewBuilder
    private var kiroCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.kiroIntegration"),
                String(localized: "settings.automation.kiro", defaultValue: "Kiro CLI Integration"),
                subtitle: kiroModel.current
                    ? String(localized: "settings.automation.kiro.subtitleOn", defaultValue: "Sidebar shows Kiro session status, notifications, and Feed tool events.")
                    : String(localized: "settings.automation.kiro.subtitleOff", defaultValue: "Kiro runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { kiroModel.current }, set: { kiroModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsKiroHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("automation.kiroNotificationLevel"),
                String(localized: "settings.automation.kiro.notificationLevel", defaultValue: "Kiro Notification Level"),
                subtitle: String(localized: "settings.automation.kiro.notificationLevel.subtitle", defaultValue: "Controls how many Kiro tool events appear in Feed."),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { kiroLevelModel.current }, set: { kiroLevelModel.set($0) })) {
                    Text(String(localized: "settings.automation.kiro.notificationLevel.minimal", defaultValue: "Minimal")).tag("minimal")
                    Text(String(localized: "settings.automation.kiro.notificationLevel.standard", defaultValue: "Standard")).tag("standard")
                    Text(String(localized: "settings.automation.kiro.notificationLevel.verbose", defaultValue: "Verbose")).tag("verbose")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("SettingsKiroNotificationLevelPicker")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.kiro.note", defaultValue: "Hooks must be installed with `cmux hooks kiro install`, then run Kiro with `kiro-cli chat --agent cmux` (or set it as your default agent). They no-op outside cmux terminals."))
        }
    }

    @ViewBuilder
    private var portCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.portBase"),
                String(localized: "settings.automation.portBase", defaultValue: "Port Base"),
                subtitle: String(localized: "settings.automation.portBase.subtitle", defaultValue: "Starting port for CMUX_PORT env var."),
                controlWidth: Self.columnWidth
            ) {
                TextField("", value: Binding(get: { portBaseModel.current }, set: { portBaseModel.set($0) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("automation.portRange"),
                String(localized: "settings.automation.portRange", defaultValue: "Port Range Size"),
                subtitle: String(localized: "settings.automation.portRange.subtitle", defaultValue: "Number of ports per workspace."),
                controlWidth: Self.columnWidth
            ) {
                TextField("", value: Binding(get: { portRangeModel.current }, set: { portRangeModel.set($0) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.port.note", defaultValue: "Each workspace gets CMUX_PORT and CMUX_PORT_END env vars with a dedicated port range. New terminals inherit these values."))
        }
    }

    private func saveSocketPassword() {
        let trimmed = socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            socketPasswordStatus = SocketPasswordStatus(
                message: String(localized: "settings.automation.socketPassword.empty", defaultValue: "Enter a password first."),
                isError: true
            )
            return
        }
        socketPasswordModel.set(trimmed)
        socketPasswordDraft = ""
        socketPasswordStatus = SocketPasswordStatus(
            message: String(localized: "settings.automation.socketPassword.saved", defaultValue: "Saved."),
            isError: false
        )
    }

    private func clearSocketPassword() {
        socketPasswordModel.reset()
        socketPasswordDraft = ""
        socketPasswordStatus = SocketPasswordStatus(
            message: String(localized: "settings.automation.socketPassword.cleared", defaultValue: "Cleared."),
            isError: false
        )
    }

}
