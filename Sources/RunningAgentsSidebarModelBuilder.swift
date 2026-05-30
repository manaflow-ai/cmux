import Foundation

@MainActor
struct RunningAgentsSidebarModelBuilder {
    typealias LatestNotificationTextProvider = @MainActor (_ workspaceId: UUID, _ surfaceId: UUID) -> String?

    let latestNotificationText: LatestNotificationTextProvider

    init(latestNotificationText: @escaping LatestNotificationTextProvider = { _, _ in nil }) {
        self.latestNotificationText = latestNotificationText
    }

    func items(for workspaces: [Workspace]) -> [RunningAgentSidebarItem] {
        workspaces.enumerated()
            .flatMap { index, workspace in
                items(for: workspace, workspaceIndex: index)
            }
            .sorted(by: precedes)
    }

    private func items(for workspace: Workspace, workspaceIndex: Int) -> [RunningAgentSidebarItem] {
        let statusEntriesByPanel = workspace.sidebarVisibleStructuredAgentStatusEntriesByPanel()
        guard !statusEntriesByPanel.isEmpty else { return [] }

        return statusEntriesByPanel.flatMap { panelId, entries in
            entries.compactMap { entry in
                guard let lifecycle = workspace.agentLifecycleStatesByPanelId[panelId]?[entry.key],
                      lifecycle.isVisibleInRunningAgentsPanel else {
                    return nil
                }
                let statusText = Self.statusText(entry: entry, lifecycle: lifecycle)
                return RunningAgentSidebarItem(
                    id: "\(workspace.id.uuidString):\(panelId.uuidString):\(entry.key)",
                    workspaceId: workspace.id,
                    tabId: workspace.id,
                    surfaceId: panelId,
                    workspaceName: workspace.title,
                    workspaceIndex: workspaceIndex,
                    agentKey: entry.key,
                    agentName: Self.agentDisplayName(for: entry.key),
                    lifecycleState: lifecycle,
                    statusText: statusText,
                    statusIcon: entry.icon,
                    statusColor: entry.color,
                    latestNotificationText: latestNotificationText(workspace.id, panelId)
                )
            }
        }
    }

    private func precedes(_ lhs: RunningAgentSidebarItem, _ rhs: RunningAgentSidebarItem) -> Bool {
        if lhs.lifecycleState.runningAgentsPanelSortRank != rhs.lifecycleState.runningAgentsPanelSortRank {
            return lhs.lifecycleState.runningAgentsPanelSortRank < rhs.lifecycleState.runningAgentsPanelSortRank
        }
        if lhs.workspaceIndex != rhs.workspaceIndex {
            return lhs.workspaceIndex < rhs.workspaceIndex
        }
        if lhs.agentName != rhs.agentName {
            return lhs.agentName.localizedStandardCompare(rhs.agentName) == .orderedAscending
        }
        return lhs.surfaceId.uuidString < rhs.surfaceId.uuidString
    }

    private static func statusText(
        entry: SidebarStatusEntry,
        lifecycle: AgentHibernationLifecycleState
    ) -> String {
        let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return lifecycle.runningAgentsPanelStatusText(agentName: agentDisplayName(for: entry.key))
    }

    private static func agentDisplayName(for key: String) -> String {
        switch key {
        case "amp":
            return String(localized: "taskManager.agent.amp", defaultValue: "Amp")
        case "antigravity":
            return String(localized: "taskManager.agent.antigravity", defaultValue: "Antigravity")
        case "claude_code":
            return String(localized: "taskManager.agent.claudeCode", defaultValue: "Claude Code")
        case "codebuddy":
            return String(localized: "taskManager.agent.codebuddy", defaultValue: "CodeBuddy")
        case "codex":
            return String(localized: "taskManager.agent.codex", defaultValue: "Codex")
        case "copilot":
            return String(localized: "taskManager.agent.copilot", defaultValue: "Copilot")
        case "cursor":
            return String(localized: "taskManager.agent.cursor", defaultValue: "Cursor")
        case "factory":
            return String(localized: "taskManager.agent.factory", defaultValue: "Factory")
        case "gemini":
            return String(localized: "taskManager.agent.gemini", defaultValue: "Gemini")
        case "grok":
            return String(localized: "taskManager.agent.grok", defaultValue: "Grok")
        case "hermes-agent":
            return String(localized: "taskManager.agent.hermesAgent", defaultValue: "Hermes Agent")
        case "opencode":
            return String(localized: "taskManager.agent.opencode", defaultValue: "OpenCode")
        case "pi":
            return String(localized: "taskManager.agent.pi", defaultValue: "Pi")
        case "qoder":
            return String(localized: "taskManager.agent.qoder", defaultValue: "Qoder")
        case "rovodev":
            return String(localized: "taskManager.agent.rovodev", defaultValue: "Rovo Dev")
        default:
            return key
        }
    }
}

private extension AgentHibernationLifecycleState {
    var isVisibleInRunningAgentsPanel: Bool {
        switch self {
        case .needsInput, .running, .idle:
            return true
        case .unknown:
            return false
        }
    }

    var runningAgentsPanelSortRank: Int {
        switch self {
        case .needsInput:
            return 0
        case .running:
            return 1
        case .idle:
            return 2
        case .unknown:
            return 3
        }
    }

    func runningAgentsPanelStatusText(agentName: String) -> String {
        switch self {
        case .needsInput:
            return String(
                format: String(localized: "agent.generic.notification.status.needsInput", defaultValue: "%@ needs input"),
                locale: .current,
                agentName
            )
        case .running:
            return String(localized: "agent.generic.status.running", defaultValue: "Running")
        case .idle:
            return String(localized: "agent.generic.notification.status.idle", defaultValue: "Idle")
        case .unknown:
            return String(localized: "sidebar.runningAgents.status.unknown", defaultValue: "Unknown")
        }
    }
}
