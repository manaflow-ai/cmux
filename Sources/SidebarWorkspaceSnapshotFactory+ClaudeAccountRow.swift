import CmuxSidebar
import Foundation

extension SidebarWorkspaceSnapshotFactory {
    /// Status row naming the non-default Claude account(s) of a workspace's
    /// live agents; nil when every agent uses the default account.
    static func claudeAccountRow(labels: [String]) -> SidebarStatusEntry? {
        guard !labels.isEmpty else { return nil }
        let joined = labels.joined(separator: ", ")
        return SidebarStatusEntry(
            key: "claude_account",
            value: String(
                localized: "sidebar.claudeAccount.row",
                defaultValue: "Claude account: \(joined)"
            ),
            icon: "person.crop.circle",
            priority: -10
        )
    }

    /// `rows` plus the account row when `appendsAccount`. Compact mode shows it in the
    /// status glyph tooltip instead, so it adds nothing there.
    func rowsIncludingClaudeAccount(
        _ rows: [SidebarStatusEntry],
        appendsAccount: Bool,
        orderedPanelIds: [UUID]
    ) -> [SidebarStatusEntry] {
        guard appendsAccount,
              let row = Self.claudeAccountRow(labels: claudeAccountLabels(orderedPanelIds: orderedPanelIds))
        else { return rows }
        return rows + [row]
    }

    /// Unique non-default Claude account labels of the workspace's live
    /// agents, in panel order. Claude agents only, from `CLAUDE_CONFIG_DIR`.
    func claudeAccountLabels(orderedPanelIds: [UUID]) -> [String] {
        guard let index = SharedLiveAgentIndex.shared.index else { return [] }
        let agents: [(kind: RestorableAgentKind, environment: [String: String]?)] = orderedPanelIds.compactMap { panelId in
            index.entry(workspaceId: workspace.id, panelId: panelId).map {
                (kind: $0.snapshot.kind, environment: $0.snapshot.launchCommand?.environment)
            }
        }
        return Self.claudeAccountLabels(agents: agents, homeDirectory: NSHomeDirectory())
    }

    static func claudeAccountLabels(
        agents: [(kind: RestorableAgentKind, environment: [String: String]?)],
        homeDirectory: String
    ) -> [String] {
        var labels: [String] = []
        for agent in agents where agent.kind == .claude {
            guard let label = SidebarAgentProfileLabel.label(
                configDirectory: agent.environment?["CLAUDE_CONFIG_DIR"],
                homeDirectory: homeDirectory
            ), label != SidebarAgentProfileLabel.routedProxyLabel, !labels.contains(label) else { continue }
            labels.append(label)
        }
        return labels
    }
}
