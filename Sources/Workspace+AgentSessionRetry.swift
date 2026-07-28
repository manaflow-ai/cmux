import CmuxSidebar
import Foundation

extension Workspace {
    func hasActiveAgentLifecycleForRetry(panelId: UUID) -> Bool {
        (agentLifecycleStatesByPanelId[panelId] ?? [:]).contains { key, lifecycle in
            !AgentHibernationLifecycleStatusKeys.isManualKey(key) &&
                (lifecycle == .running || lifecycle == .needsInput)
        }
    }

    func managedAgentRetryBinding(panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        guard panels[panelId] is TerminalPanel,
              let binding = surfaceResumeBindingsByPanelId[panelId],
              binding.isAgentHookBinding,
              binding.checkpointId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return binding
    }

    func sendManagedAgentRetry(
        binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) -> Bool {
        let currentBinding = surfaceResumeBindingsByPanelId[panelId]
        guard currentBinding == nil || currentBinding == binding,
              let panel = panels[panelId] as? TerminalPanel else {
            return false
        }
        let input: String? = switch binding.launchFlavor {
        case .local:
            binding.startupInputWithLauncherScript(
                allowLauncherScript: true,
                repairPortableAgentExecutable: true
            )
        case .persistentSSH:
            binding.remoteStartupInputWithLauncherScript(allowLauncherScript: false)
        }
        guard let input else { return false }
        return panel.sendInputResult(input).accepted
    }

    func showAgentRetryScheduled(
        panelId: UUID,
        exitCode: Int,
        attempt: Int,
        maximumAttempts: Int
    ) {
        let status = String.localizedStringWithFormat(
            String(
                localized: "agent.autoRetry.status.retrying",
                defaultValue: "Retrying agent (attempt %lld/%lld)…"
            ),
            Int64(attempt),
            Int64(maximumAttempts)
        )
        sidebarMetadata.addStatusEntry(SidebarStatusEntry(
            key: agentRetryStatusKey(panelId: panelId),
            value: status,
            icon: "arrow.clockwise",
            color: "#F59E0B",
            priority: 200
        ))
        let logMessage = String.localizedStringWithFormat(
            String(
                localized: "agent.autoRetry.log.scheduled",
                defaultValue: "Agent exited with code %lld; retrying (attempt %lld/%lld)."
            ),
            Int64(exitCode),
            Int64(attempt),
            Int64(maximumAttempts)
        )
        sidebarMetadata.appendLogEntry(
            message: logMessage,
            level: .warning,
            source: "agent-auto-retry"
        )
    }

    func showAgentRetriesExhausted(
        panelId: UUID,
        exitCode: Int?,
        maximumAttempts: Int
    ) {
        sidebarMetadata.addStatusEntry(SidebarStatusEntry(
            key: agentRetryStatusKey(panelId: panelId),
            value: String(
                localized: "agent.autoRetry.status.exhausted",
                defaultValue: "Agent auto-retry exhausted"
            ),
            icon: "exclamationmark.arrow.triangle.2.circlepath",
            color: "#EF4444",
            priority: 200
        ))
        let logMessage = String.localizedStringWithFormat(
            String(
                localized: "agent.autoRetry.log.exhausted",
                defaultValue: "Agent exited with code %lld after %lld retries; automatic retries exhausted."
            ),
            Int64(exitCode ?? -1),
            Int64(maximumAttempts)
        )
        sidebarMetadata.appendLogEntry(
            message: logMessage,
            level: .error,
            source: "agent-auto-retry"
        )
        postAgentRetryNotification(
            panelId: panelId,
            body: String(
                localized: "agent.autoRetry.notification.exhausted.body",
                defaultValue: "The agent could not be resumed after three automatic retries."
            )
        )
    }

    func showAgentRetryLaunchFailure(panelId: UUID) {
        sidebarMetadata.addStatusEntry(SidebarStatusEntry(
            key: agentRetryStatusKey(panelId: panelId),
            value: String(
                localized: "agent.autoRetry.status.exhausted",
                defaultValue: "Agent auto-retry exhausted"
            ),
            icon: "exclamationmark.arrow.triangle.2.circlepath",
            color: "#EF4444",
            priority: 200
        ))
        let message = String(
            localized: "agent.autoRetry.log.launchFailed",
            defaultValue: "The agent resume command could not be sent; automatic retries stopped."
        )
        sidebarMetadata.appendLogEntry(
            message: message,
            level: .error,
            source: "agent-auto-retry"
        )
        postAgentRetryNotification(panelId: panelId, body: message)
    }

    func removeAgentRetryStatusEntry(panelId: UUID) {
        statusEntries.removeValue(forKey: agentRetryStatusKey(panelId: panelId))
    }

    func removeAllAgentRetryStatusEntries() {
        let prefix = "agent.auto_retry."
        statusEntries = statusEntries.filter { !$0.key.hasPrefix(prefix) }
    }

    private func postAgentRetryNotification(panelId: UUID, body: String) {
        AppDelegate.shared?.notificationStore?.addNotification(
            tabId: id,
            surfaceId: panelId,
            title: String(
                localized: "agent.autoRetry.notification.exhausted.title",
                defaultValue: "Agent retries exhausted"
            ),
            subtitle: title,
            body: body,
            cooldownKey: "agent-auto-retry-exhausted-\(id.uuidString)-\(panelId.uuidString)",
            cooldownInterval: 60
        )
    }

    private func agentRetryStatusKey(panelId: UUID) -> String {
        "agent.auto_retry.\(panelId.uuidString.lowercased())"
    }
}
