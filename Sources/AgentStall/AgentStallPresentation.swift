import CmuxNotifications
import CmuxSidebar
import CMUXAgentLaunch
import Foundation

/// Localized sidebar and notification presentation for classified stalls.
@MainActor
struct AgentStallPresentation {
    let notificationStore: TerminalNotificationStore

    func setRetryStatus(
        owner: ControlSidebarPanelOwner,
        panelID: UUID,
        provider: String,
        attempt: Int,
        maximumAttempts: Int
    ) {
        let value = String.localizedStringWithFormat(
            String(
                localized: "agent.stall.status.retrying",
                defaultValue: "Retrying %@ (attempt %lld/%lld)…"
            ),
            providerDisplayName(provider),
            Int64(attempt),
            Int64(maximumAttempts)
        )
        owner.setStatusEntry(
            SidebarStatusEntry(
                key: Self.statusKey(panelID),
                value: value,
                icon: "arrow.clockwise",
                color: "#F59E0B",
                priority: 250
            ),
            key: Self.statusKey(panelID),
            panelId: panelID
        )
    }

    func presentHumanRequired(
        owner: ControlSidebarPanelOwner,
        panelID: UUID,
        provider: String,
        cause: AgentStallCause,
        suggestedActionID: String,
        generation: UInt64
    ) {
        let causeText = localizedCause(cause)
        let providerText = providerDisplayName(provider)
        let status = String.localizedStringWithFormat(
            String(
                localized: "agent.stall.status.humanRequired",
                defaultValue: "%@ stalled: %@"
            ),
            providerText,
            causeText
        )
        owner.setStatusEntry(
            SidebarStatusEntry(
                key: Self.statusKey(panelID),
                value: status,
                icon: "exclamationmark.triangle.fill",
                color: "#EF4444",
                priority: 300
            ),
            key: Self.statusKey(panelID),
            panelId: panelID
        )

        let body = String.localizedStringWithFormat(
            String(
                localized: "agent.stall.notification.body",
                defaultValue: "Workspace “%@”: %@ stopped because of %@. %@"
            ),
            owner.agentStallTitle,
            providerText,
            causeText,
            localizedSuggestedAction(suggestedActionID)
        )
        notificationStore.addNotification(
            tabId: owner.id,
            surfaceId: panelID,
            title: String(
                localized: "agent.stall.notification.title",
                defaultValue: "Agent action required"
            ),
            subtitle: owner.agentStallTitle,
            body: body,
            cooldownKey: "agent-stall-\(owner.id.uuidString)-\(panelID.uuidString)-\(generation)-\(cause.rawValue)",
            cooldownInterval: 60
        )
    }

    func presentRetryExhausted(
        owner: ControlSidebarPanelOwner,
        panelID: UUID,
        generation: UInt64
    ) {
        owner.setStatusEntry(
            SidebarStatusEntry(
                key: Self.statusKey(panelID),
                value: String(
                    localized: "agent.stall.status.exhausted",
                    defaultValue: "Agent retry limit reached"
                ),
                icon: "exclamationmark.arrow.triangle.2.circlepath",
                color: "#EF4444",
                priority: 250
            ),
            key: Self.statusKey(panelID),
            panelId: panelID
        )
        notificationStore.addNotification(
            tabId: owner.id,
            surfaceId: panelID,
            title: String(
                localized: "agent.stall.notification.exhausted.title",
                defaultValue: "Agent retry limit reached"
            ),
            subtitle: owner.agentStallTitle,
            body: String(
                localized: "agent.stall.notification.exhausted.body",
                defaultValue: "Automatic retries stopped. Review the pane and resume the session manually."
            ),
            cooldownKey: "agent-stall-exhausted-\(owner.id.uuidString)-\(panelID.uuidString)-\(generation)",
            cooldownInterval: 60
        )
    }

    func clearStatus(owner: ControlSidebarPanelOwner, panelID: UUID) {
        owner.clearStatusEntry(key: Self.statusKey(panelID), panelId: panelID)
    }

    static func statusKey(_ panelID: UUID) -> String {
        "agent.stall.\(panelID.uuidString.lowercased())"
    }

    private func providerDisplayName(_ provider: String) -> String {
        provider == "claude"
            ? String(localized: "agent.stall.provider.claude", defaultValue: "Claude Code")
            : String(localized: "agent.stall.provider.codex", defaultValue: "Codex")
    }

    private func localizedCause(_ cause: AgentStallCause) -> String {
        switch cause {
        case .transientTransport:
            String(localized: "agent.stall.cause.transport", defaultValue: "a transient network or server error")
        case .rateLimit:
            String(localized: "agent.stall.cause.rateLimit", defaultValue: "a provider rate limit")
        case .overload:
            String(localized: "agent.stall.cause.overload", defaultValue: "a provider overload")
        case .safeguardRefusal:
            String(localized: "agent.stall.cause.safeguard", defaultValue: "a provider safeguard refusal")
        case .quotaExhausted:
            String(localized: "agent.stall.cause.quota", defaultValue: "an exhausted credit or usage quota")
        case .authenticationExpired:
            String(localized: "agent.stall.cause.auth", defaultValue: "expired authentication")
        }
    }

    private func localizedSuggestedAction(_ id: String) -> String {
        switch id {
        case "trustedAccess":
            String(localized: "agent.stall.action.trustedAccess", defaultValue: "Apply for Trusted Access or change the request, then resume the session.")
        case "restoreCredits":
            String(localized: "agent.stall.action.restoreCredits", defaultValue: "Restore provider credits or quota, then resume the session.")
        case "reauthenticate":
            String(localized: "agent.stall.action.reauthenticate", defaultValue: "Sign in again or refresh provider credentials, then resume the session.")
        default:
            String(localized: "agent.stall.action.manualResume", defaultValue: "Review the pane and resume the session manually.")
        }
    }
}
