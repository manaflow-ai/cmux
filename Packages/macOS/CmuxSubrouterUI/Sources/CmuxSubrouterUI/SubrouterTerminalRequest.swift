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
    /// Pass the explicit local or named-server target selected by the host.
    public static func addAccount(
        provider: SubrouterProvider,
        target: SubrouterAccountTarget = .local
    ) -> SubrouterTerminalRequest? {
        guard let command = SubrouterMaintenanceCommand.addAccount(
            provider: provider,
            target: target
        ) else {
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

    /// The first-run setup request: installs the sr CLI when missing,
    /// starts the local daemon, and prints next steps (add accounts).
    public static func setup() -> SubrouterTerminalRequest {
        SubrouterTerminalRequest(
            workspaceTitle: String(
                localized: "subrouter.terminal.setupTitle",
                defaultValue: "Set up subrouter"
            ),
            command: SubrouterMaintenanceCommand.setup,
            runsImmediately: true
        )
    }

    /// The connect-to-hosted-server request. Pre-typed, never auto-run:
    /// the user fills in the server name and URL before pressing Return.
    public static func connectServer() -> SubrouterTerminalRequest {
        SubrouterTerminalRequest(
            workspaceTitle: String(
                localized: "subrouter.terminal.connectServerTitle",
                defaultValue: "Connect subrouter server"
            ),
            command: SubrouterMaintenanceCommand.connectServer,
            runsImmediately: false
        )
    }

    /// The re-login request for an account at the explicit target, or `nil`
    /// when unsupported.
    public static func signIn(
        account: SubrouterAccountUsageStatus,
        target: SubrouterAccountTarget = .local
    ) -> SubrouterTerminalRequest? {
        guard let command = SubrouterMaintenanceCommand.signIn(
            provider: account.provider,
            accountID: account.id,
            target: target
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

    /// The remove request for an account at the explicit target, or `nil`
    /// when unsupported.
    /// Pre-typed, never auto-run: pressing Return is the confirmation.
    public static func removeAccount(
        account: SubrouterAccountUsageStatus,
        target: SubrouterAccountTarget = .local
    ) -> SubrouterTerminalRequest? {
        guard let command = SubrouterMaintenanceCommand.removeAccount(
            provider: account.provider,
            accountID: account.id,
            target: target
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
