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
              let row = Self.claudeAccountRow(labels: agentProfileLabels(orderedPanelIds: orderedPanelIds))
        else { return rows }
        return rows + [row]
    }
}
