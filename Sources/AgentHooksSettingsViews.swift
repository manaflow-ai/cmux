import AppKit
import SwiftUI

struct AgentHooksSettingsCard: View {
    @AppStorage(AgentHookIntegrationSettings.promptEnabledKey)
    private var promptEnabled = AgentHookIntegrationSettings.defaultPromptEnabled
    @State private var refreshToken: UInt64 = 0

    private var promptEnabledBinding: Binding<Bool> {
        Binding(
            get: { promptEnabled },
            set: { newValue in
                AgentHookIntegrationSettings.setPromptEnabled(newValue)
                promptEnabled = newValue
            }
        )
    }

    var body: some View {
        let _ = refreshToken
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.automation.agentHooks.title", defaultValue: "Agent Hooks"),
                subtitle: String(localized: "settings.automation.agentHooks.subtitle", defaultValue: "Install hooks for notifications and session restore."),
                searchAnchorID: SettingsSearchIndex.settingID(for: .automation, idSuffix: "agent-hooks")
            ) {
                Toggle("", isOn: promptEnabledBinding)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsAgentHookPromptToggle")
            }

            SettingsCardDivider()

            SettingsCardNote(String(localized: "settings.automation.agentHooks.note", defaultValue: "Hooks let cmux show agent notifications and restore sessions after cmux restarts. The prompt only appears after you run a supported agent command."))

            ForEach(AgentHookIntegrationSettings.allAgents) { agent in
                SettingsCardDivider()
                AgentHookSettingsRow(agent: agent, refreshToken: $refreshToken)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentHookIntegrationSettings.statusDidChangeNotification)) { _ in
            refreshToken &+= 1
        }
    }
}

struct AgentHookSettingsRow: View {
    let agent: AgentHookIntegration
    @Binding var refreshToken: UInt64
    @State private var reviewAgent: AgentHookIntegration?
    @State private var status: AgentHookIntegrationStatus = .unknown

    var body: some View {
        let currentStatus = status
        SettingsCardRow(
            configurationReview: .settingsOnly,
            agent.displayName,
            subtitle: AgentHookIntegrationSettings.statusSubtitle(for: agent, status: currentStatus)
        ) {
            HStack(spacing: 8) {
                AgentHookStatusPill(
                    text: AgentHookIntegrationSettings.statusLabel(for: currentStatus),
                    isActive: currentStatus.isActive,
                    isUpdateAvailable: currentStatus.isUpdateAvailable
                )
                Button(buttonTitle(for: currentStatus)) {
                    reviewAgent = agent
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(currentStatus.isActive)
            }
        }
        .sheet(item: $reviewAgent) { agent in
            AgentHookDiffReviewView(agent: agent) {
                refreshToken &+= 1
            }
        }
        .task(id: refreshToken) {
            await refreshStatus()
        }
    }

    private func buttonTitle(for status: AgentHookIntegrationStatus) -> String {
        if status.isActive {
            return String(localized: "settings.automation.agentHooks.installed", defaultValue: "Installed")
        }
        return String(localized: "settings.automation.agentHooks.review", defaultValue: "Review")
    }

    @MainActor
    private func refreshStatus() async {
        let agent = agent
        let nextStatus = await Task.detached(priority: .utility) {
            AgentHookIntegrationSettings.status(for: agent)
        }.value
        status = nextStatus
    }
}

struct AgentHookStatusPill: View {
    let text: String
    let isActive: Bool
    let isUpdateAvailable: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
    }

    private var foregroundColor: Color {
        if isActive { return .green }
        if isUpdateAvailable { return .orange }
        return .secondary
    }

    private var backgroundColor: Color {
        if isActive { return Color.green.opacity(0.12) }
        if isUpdateAvailable { return Color.orange.opacity(0.12) }
        return Color.secondary.opacity(0.12)
    }
}
