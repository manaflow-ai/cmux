public import CmuxSubrouter

/// A request from the Agents panel to open a terminal for an `sr`
/// maintenance command. The host owns workspace creation; the panel only
/// describes what to run.
public struct SubrouterTerminalRequest: Sendable, Equatable {
    /// The title for the new workspace.
    public let workspaceTitle: String
    /// The shell command to place in the terminal.
    public let command: String
    /// Whether the command runs immediately. Destructive commands pass
    /// `false` so they are pre-typed and Return is the confirmation.
    public let runsImmediately: Bool

    /// The add-account request for a provider, or `nil` when unsupported.
    public static func addAccount(provider: SubrouterProvider) -> SubrouterTerminalRequest? {
        guard let command = SubrouterMaintenanceCommand.addAccount(provider: provider) else {
            return nil
        }
        return SubrouterTerminalRequest(
            workspaceTitle: String(
                localized: "subrouter.provider.addAccount",
                defaultValue: "Add \(provider.displayName) account"
            ),
            command: command,
            runsImmediately: true
        )
    }

    /// The re-login request for an account, or `nil` when unsupported.
    public static func signIn(account: SubrouterAccountUsageStatus) -> SubrouterTerminalRequest? {
        guard let command = SubrouterMaintenanceCommand.signIn(
            provider: account.provider,
            accountID: account.id
        ) else {
            return nil
        }
        return SubrouterTerminalRequest(
            workspaceTitle: String(
                localized: "subrouter.terminal.signInTitle",
                defaultValue: "Sign in \(account.displayName)"
            ),
            command: command,
            runsImmediately: true
        )
    }

    /// The remove request for an account, or `nil` when unsupported.
    /// Pre-typed, never auto-run: pressing Return is the confirmation.
    public static func removeAccount(account: SubrouterAccountUsageStatus) -> SubrouterTerminalRequest? {
        guard let command = SubrouterMaintenanceCommand.removeAccount(
            provider: account.provider,
            accountID: account.id
        ) else {
            return nil
        }
        return SubrouterTerminalRequest(
            workspaceTitle: String(
                localized: "subrouter.terminal.removeTitle",
                defaultValue: "Remove \(account.displayName)"
            ),
            command: command,
            runsImmediately: false
        )
    }
}
