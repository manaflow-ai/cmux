import CMUXAgentLaunch

/// The accounts a Claude pane offers under Switch Claude Account, in the terminal context menu
/// and as command palette entries.
///
/// The current account is listed but cannot be picked. When the pane runs under an account the
/// user never registered, that account comes first so the menu still shows where the pane is.
struct ClaudeAccountSwitchMenuModel: Equatable, Sendable {
    /// One account row.
    struct Entry: Equatable, Sendable {
        /// The account name, shown as the row title and passed to the switch.
        let accountName: String
        /// Whether the pane's Claude runs under this account. A current row is checked and disabled.
        let isCurrent: Bool
    }

    /// Rows in display order.
    let entries: [Entry]

    /// Builds the rows, or returns `nil` when the registry holds fewer than two accounts.
    ///
    /// - Parameters:
    ///   - registry: The accounts registered for the pane.
    ///   - current: The account the pane's Claude session runs under.
    init?(registry: ClaudeAccountRegistry, current: ClaudeAccount) {
        guard registry.accounts.count >= 2 else { return nil }
        // The config directory identifies an account; the default one has none.
        let registered = registry.accounts.map {
            Entry(accountName: $0.name, isCurrent: $0.configDirectory == current.configDirectory)
        }
        if registered.contains(where: \.isCurrent) {
            entries = registered
        } else {
            entries = [Entry(accountName: current.name, isCurrent: true)] + registered
        }
    }

    /// The accounts a switch can target: every row except the current account.
    var switchTargetNames: [String] {
        entries.filter { !$0.isCurrent }.map(\.accountName)
    }
}
