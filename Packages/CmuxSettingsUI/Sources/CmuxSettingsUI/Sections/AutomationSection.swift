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
    private let defaultsStore: UserDefaultsSettingsStore
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog

    @State private var socketPasswordModel: JSONValueModel<String>?
    @State private var socketPasswordDraft: String = ""

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog
    ) {
        self.defaultsStore = defaultsStore
        self.jsonStore = jsonStore
        self.catalog = catalog
    }

    private static let columnWidth: CGFloat = 220

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionHeader(String(localized: "settings.section.automation", defaultValue: "Automation"))

            socketControlCard
            claudeCodeCard
            claudePathCard
            ripgrepPathCard
            suppressSubagentCard
            cursorCard
            geminiCard
            portCard
        }
        .task {
            if socketPasswordModel == nil {
                socketPasswordModel = JSONValueModel(store: jsonStore, key: catalog.automation.socketPassword)
            }
        }
    }

    @ViewBuilder
    private var socketControlCard: some View {
        let modeModel = DefaultsValueModel(store: defaultsStore, key: catalog.automation.socketControlMode)
        let isPassword = modeModel.current == .password
        let isAllowAll = modeModel.current == .allowAll
        let hasPassword = !(socketPasswordModel?.current.isEmpty ?? true)

        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.socketControlMode"),
                String(localized: "settings.automation.socketMode", defaultValue: "Socket Control Mode"),
                subtitle: socketModeDescription(modeModel.current),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { modeModel.current }, set: { modeModel.set($0) })) {
                    Text(String(localized: "settings.automation.socketMode.off", defaultValue: "Off")).tag(SocketControlMode.off)
                    Text(String(localized: "settings.automation.socketMode.cmuxOnly", defaultValue: "Bundled CLI Only")).tag(SocketControlMode.cmuxOnly)
                    Text(String(localized: "settings.automation.socketMode.automation", defaultValue: "Automation Tools")).tag(SocketControlMode.automation)
                    Text(String(localized: "settings.automation.socketMode.password", defaultValue: "Password Required")).tag(SocketControlMode.password)
                    Text(String(localized: "settings.automation.socketMode.allowAll", defaultValue: "Allow All Local Clients")).tag(SocketControlMode.allowAll)
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
            }

            if isAllowAll {
                SettingsCardDivider()
                Text(String(localized: "settings.automation.openAccessWarning", defaultValue: "Warning: Full open access makes the control socket world-readable/writable on this Mac and disables auth checks. Use only for local debugging."))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            SettingsCardNote(String(localized: "settings.automation.socketOverrides.note", defaultValue: "Overrides: CMUX_SOCKET_ENABLE, CMUX_SOCKET_MODE, and CMUX_SOCKET_PATH (set CMUX_ALLOW_SOCKET_OVERRIDE=1 for stable/nightly builds)."))
        }
    }

    @ViewBuilder
    private var claudeCodeCard: some View {
        let model = DefaultsValueModel(store: defaultsStore, key: catalog.integrations.claudeCodeHooksEnabled)
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.claudeCodeIntegration"),
                String(localized: "settings.automation.claudeCode", defaultValue: "Claude Code Integration"),
                subtitle: model.current
                    ? String(localized: "settings.automation.claudeCode.subtitleOn", defaultValue: "Sidebar shows Claude session status and notifications.")
                    : String(localized: "settings.automation.claudeCode.subtitleOff", defaultValue: "Claude Code runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsClaudeCodeHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.claudeCode.note", defaultValue: "When enabled, cmux wraps the claude command to inject session tracking and notification hooks. Disable if you prefer to manage Claude Code hooks yourself."))
        }
    }

    @ViewBuilder
    private var claudePathCard: some View {
        let model = DefaultsValueModel(store: defaultsStore, key: catalog.integrations.claudeCodeCustomClaudePath)
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.claudeBinaryPath"),
                String(localized: "settings.automation.claudeCode.customPath", defaultValue: "Claude Binary Path"),
                subtitle: String(localized: "settings.automation.claudeCode.customPath.subtitle", defaultValue: "Custom path to the claude binary. Leave empty to use PATH.")
            ) {
                TextField(
                    String(localized: "settings.automation.claudeCode.customPath.placeholder", defaultValue: "e.g. /usr/local/bin/claude"),
                    text: Binding(get: { model.current }, set: { model.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
        }
    }

    @ViewBuilder
    private var ripgrepPathCard: some View {
        let model = DefaultsValueModel(store: defaultsStore, key: catalog.integrations.ripgrepCustomBinaryPath)
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.ripgrepBinaryPath"),
                String(localized: "settings.automation.ripgrep.customPath", defaultValue: "Ripgrep Binary Path"),
                subtitle: String(localized: "settings.automation.ripgrep.customPath.subtitle", defaultValue: "Custom path to the rg binary used by Find. Leave empty to use common install locations and PATH.")
            ) {
                TextField(
                    String(localized: "settings.automation.ripgrep.customPath.placeholder", defaultValue: "e.g. /etc/profiles/per-user/you/bin/rg"),
                    text: Binding(get: { model.current }, set: { model.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
        }
    }

    @ViewBuilder
    private var suppressSubagentCard: some View {
        let model = DefaultsValueModel(store: defaultsStore, key: catalog.integrations.suppressSubagentNotifications)
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.suppressSubagentNotifications"),
                String(localized: "settings.automation.suppressSubagentNotifications", defaultValue: "Suppress Subagent Notifications"),
                subtitle: model.current
                    ? String(localized: "settings.automation.suppressSubagentNotifications.subtitleOn", defaultValue: "Child agent completions stay in Feed without notifications.")
                    : String(localized: "settings.automation.suppressSubagentNotifications.subtitleOff", defaultValue: "Child agent completions notify like top-level agents.")
            ) {
                Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsSuppressSubagentNotificationsToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.suppressSubagentNotifications.note", defaultValue: "Uses process ancestry from hook processes. Disable if nested Codex or Claude sessions should trigger completion notifications."))
        }
    }

    @ViewBuilder
    private var cursorCard: some View {
        let model = DefaultsValueModel(store: defaultsStore, key: catalog.integrations.cursorHooksEnabled)
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.cursorIntegration"),
                String(localized: "settings.automation.cursor", defaultValue: "Cursor Integration"),
                subtitle: model.current
                    ? String(localized: "settings.automation.cursor.subtitleOn", defaultValue: "Sidebar shows Cursor agent status and notifications.")
                    : String(localized: "settings.automation.cursor.subtitleOff", defaultValue: "Cursor runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
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
        let model = DefaultsValueModel(store: defaultsStore, key: catalog.integrations.geminiHooksEnabled)
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.geminiIntegration"),
                String(localized: "settings.automation.gemini", defaultValue: "Gemini CLI Integration"),
                subtitle: model.current
                    ? String(localized: "settings.automation.gemini.subtitleOn", defaultValue: "Sidebar shows Gemini session status and notifications.")
                    : String(localized: "settings.automation.gemini.subtitleOff", defaultValue: "Gemini runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsGeminiHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.gemini.note", defaultValue: "Hooks must be installed with `cmux hooks gemini install`. They no-op outside cmux terminals."))
        }
    }

    @ViewBuilder
    private var portCard: some View {
        let baseModel = DefaultsValueModel(store: defaultsStore, key: catalog.automation.portBase)
        let rangeModel = DefaultsValueModel(store: defaultsStore, key: catalog.automation.portRange)
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.portBase"),
                String(localized: "settings.automation.portBase", defaultValue: "Port Base"),
                subtitle: String(localized: "settings.automation.portBase.subtitle", defaultValue: "Starting port for CMUX_PORT env var."),
                controlWidth: Self.columnWidth
            ) {
                TextField("", value: Binding(get: { baseModel.current }, set: { baseModel.set($0) }), format: .number)
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
                TextField("", value: Binding(get: { rangeModel.current }, set: { rangeModel.set($0) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.port.note", defaultValue: "Each workspace gets CMUX_PORT and CMUX_PORT_END env vars with a dedicated port range. New terminals inherit these values."))
        }
    }

    private func saveSocketPassword() {
        guard let model = socketPasswordModel else { return }
        let trimmed = socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.set(trimmed)
        socketPasswordDraft = ""
    }

    private func clearSocketPassword() {
        socketPasswordModel?.reset()
        socketPasswordDraft = ""
    }

    private func socketModeDescription(_ mode: SocketControlMode) -> String {
        switch mode {
        case .off: return String(localized: "settings.automation.socketMode.off.subtitle", defaultValue: "External programmatic control is disabled.")
        case .cmuxOnly: return String(localized: "settings.automation.socketMode.cmuxOnly.subtitle", defaultValue: "Only the cmux CLI bundled in this app can talk to the socket.")
        case .automation: return String(localized: "settings.automation.socketMode.automation.subtitle", defaultValue: "Allowlisted automation tools can talk to the socket.")
        case .password: return String(localized: "settings.automation.socketMode.password.subtitle", defaultValue: "Clients must present the configured password.")
        case .allowAll: return String(localized: "settings.automation.socketMode.allowAll.subtitle", defaultValue: "Every local process can talk to the socket. Debug only.")
        }
    }
}
