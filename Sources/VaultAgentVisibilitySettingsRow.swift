import SwiftUI

struct VaultAgentVisibilitySettingsRow: View {
    let agent: SessionAgent
    @AppStorage private var isEnabled: Bool

    init(agent: SessionAgent) {
        self.agent = agent
        _isEnabled = AppStorage(
            wrappedValue: VaultAgentVisibilitySettings.defaultValue,
            VaultAgentVisibilitySettings.key(for: agent)
        )
    }

    private var title: String {
        switch agent {
        case .claude:
            return String(localized: "settings.terminal.vault.claude", defaultValue: "Show Claude Code Sessions")
        case .codex:
            return String(localized: "settings.terminal.vault.codex", defaultValue: "Show Codex Sessions")
        case .opencode:
            return String(localized: "settings.terminal.vault.opencode", defaultValue: "Show OpenCode Sessions")
        case .rovodev:
            return String(localized: "settings.terminal.vault.rovodev", defaultValue: "Show Rovo Dev Sessions")
        }
    }

    private var subtitle: String {
        switch (agent, isEnabled) {
        case (.claude, true):
            return String(localized: "settings.terminal.vault.claude.subtitleOn", defaultValue: "Claude Code sessions appear in the Vault and are scanned for resume.")
        case (.claude, false):
            return String(localized: "settings.terminal.vault.claude.subtitleOff", defaultValue: "Claude Code sessions are hidden from the Vault and skipped during scans.")
        case (.codex, true):
            return String(localized: "settings.terminal.vault.codex.subtitleOn", defaultValue: "Codex sessions appear in the Vault and are scanned for resume.")
        case (.codex, false):
            return String(localized: "settings.terminal.vault.codex.subtitleOff", defaultValue: "Codex sessions are hidden from the Vault and skipped during scans.")
        case (.opencode, true):
            return String(localized: "settings.terminal.vault.opencode.subtitleOn", defaultValue: "OpenCode sessions appear in the Vault and are scanned for resume.")
        case (.opencode, false):
            return String(localized: "settings.terminal.vault.opencode.subtitleOff", defaultValue: "OpenCode sessions are hidden from the Vault and skipped during scans.")
        case (.rovodev, true):
            return String(localized: "settings.terminal.vault.rovodev.subtitleOn", defaultValue: "Rovo Dev sessions appear in the Vault and are scanned for resume.")
        case (.rovodev, false):
            return String(localized: "settings.terminal.vault.rovodev.subtitleOff", defaultValue: "Rovo Dev sessions are hidden from the Vault and skipped during scans.")
        }
    }

    var body: some View {
        SettingsCardRow(
            configurationReview: .json(VaultAgentVisibilitySettings.settingsJSONPath(for: agent)),
            title,
            subtitle: subtitle
        ) {
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTerminalVault\(agent.rawValue)SessionsToggle")
                .accessibilityLabel(title)
                .onChange(of: isEnabled) { _, _ in
                    VaultAgentVisibilitySettings.notifyDidChange()
                }
        }
    }
}
