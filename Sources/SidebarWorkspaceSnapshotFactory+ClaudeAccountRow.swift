import CmuxSidebar
import Foundation

extension SidebarWorkspaceSnapshotFactory {
    /// Status row naming the non-default Claude account(s) of a workspace's
    /// live agents; nil when every agent uses the default account.
    static func claudeAccountRow(labels: [String]) -> SidebarStatusEntry? {
        guard !labels.isEmpty else { return nil }
        let joined = labels.joined(separator: ", ")
        return SidebarStatusEntry(
            key: claudeAccountRowKey,
            value: String(
                localized: "sidebar.claudeAccount.row",
                defaultValue: "Claude account: \(joined)"
            ),
            icon: "person.crop.circle",
            priority: -10
        )
    }

    /// `rows` plus the account row when `appendsAccount`. Compact mode shows it in the
    /// status glyph tooltip instead, so it adds nothing there. The row reflects the panes, so it
    /// replaces a status entry another caller set under the same key rather than showing twice.
    func rowsIncludingClaudeAccount(
        _ rows: [SidebarStatusEntry],
        appendsAccount: Bool,
        orderedPanelIds: [UUID]
    ) -> [SidebarStatusEntry] {
        guard appendsAccount,
              let row = Self.claudeAccountRow(labels: claudeAccountLabels(orderedPanelIds: orderedPanelIds))
        else { return rows }
        return rows.filter { $0.key != row.key } + [row]
    }

    /// Unique non-default Claude account labels of the workspace's panes, in panel order, from
    /// `CLAUDE_CONFIG_DIR`. A pane cmux switched to another account names that account (its
    /// `claudeAccountEnvironment`): the label is the pane's account (spec D9), and the index
    /// learns it only once the resumed Claude starts, or never when no resume ran. Every other
    /// pane names the account of its live Claude agent in the index.
    func claudeAccountLabels(orderedPanelIds: [UUID]) -> [String] {
        Self.claudeAccountLabels(workspace: workspace, orderedPanelIds: orderedPanelIds)
    }

    /// Whether `shownEntries`, a cached row's metadata entries (`nil` without a cached row), show
    /// another Claude account row than `workspace`'s panes give now. A full index reload asks this
    /// instead of rebuilding every row: it reads only each pane's account record and index entry.
    @MainActor
    static func claudeAccountRowIsStale(workspace: Workspace, shownEntries: [SidebarStatusEntry]?) -> Bool {
        guard let shownEntries else { return true }
        let current = claudeAccountRow(labels: claudeAccountLabels(
            workspace: workspace,
            orderedPanelIds: workspace.sidebarOrderedPanelIds()
        ))
        return shownEntries.first { $0.key == claudeAccountRowKey }?.value != current?.value
    }

    /// The status key of the Claude account row.
    static let claudeAccountRowKey = "claude_account"

    /// `claudeAccountLabels(orderedPanelIds:)` for `workspace`.
    static func claudeAccountLabels(workspace: Workspace, orderedPanelIds: [UUID]) -> [String] {
        let index = SharedLiveAgentIndex.shared.index
        let agents: [(kind: RestorableAgentKind, environment: [String: String]?)] = orderedPanelIds.compactMap { panelId in
            accountLabelAgent(
                switchedAccount: workspace.terminalPanel(for: panelId)?.claudeAccountEnvironment?.accountEnvironment,
                indexed: index?.entry(workspaceId: workspace.id, panelId: panelId).map {
                    (kind: $0.snapshot.kind, environment: $0.snapshot.launchCommand?.environment)
                }
            )
        }
        return claudeAccountLabels(agents: agents, homeDirectory: NSHomeDirectory())
    }

    /// The agent a pane names in account labels, from the account cmux switched the pane to
    /// (`switchedAccount`) and the pane's agent-index entry (`indexed`).
    static func accountLabelAgent(
        switchedAccount: [String: String]?,
        indexed: (kind: RestorableAgentKind, environment: [String: String]?)?
    ) -> (kind: RestorableAgentKind, environment: [String: String]?)? {
        if let switchedAccount { return (kind: .claude, environment: switchedAccount) }
        return indexed
    }

    static func claudeAccountLabels(
        agents: [(kind: RestorableAgentKind, environment: [String: String]?)],
        homeDirectory: String
    ) -> [String] {
        var labels: [String] = []
        // Emitted labels, so a workspace with many panes dedupes in one pass, in panel order.
        var emitted: Set<String> = []
        for agent in agents where agent.kind == .claude {
            guard let label = SidebarAgentProfileLabel.label(
                configDirectory: agent.environment?["CLAUDE_CONFIG_DIR"],
                homeDirectory: homeDirectory
            ), label != SidebarAgentProfileLabel.routedProxyLabel, emitted.insert(label).inserted else { continue }
            labels.append(label)
        }
        return labels
    }
}
