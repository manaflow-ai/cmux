/// Builders for the `sr` shell commands behind the panel's account
/// management actions (add, re-auth, remove). The panel opens these in a
/// real cmux terminal instead of running them silently: OAuth logins are
/// interactive, and destructive commands stay visible to the user.
public enum SubrouterMaintenanceCommand {
    /// The command that starts an interactive add-account login for the
    /// provider, or `nil` when the provider has no add verb.
    ///
    /// With a `serverName`, the login chains into the upload that puts the
    /// new account on that server's pool (`sr server sync` for Codex,
    /// `sr claude push` for Claude profiles) — the panel may be watching a
    /// remote server, where a purely local login would never appear.
    public static func addAccount(
        provider: SubrouterProvider,
        serverName: String? = nil
    ) -> String? {
        switch provider {
        case .codex:
            guard let serverName else { return "cmux sr add" }
            return "cmux sr add && cmux sr server sync \(shellQuoted(serverName)) --yes"
        case .claude:
            guard serverName != nil else { return "cmux sr claude add" }
            return "cmux sr claude add && cmux sr claude push"
        default:
            return nil
        }
    }

    /// The command that re-runs the provider's login for an existing
    /// account (Codex OAuth infers the account from the login; Claude
    /// re-auths the named profile), or `nil` when unsupported.
    public static func signIn(provider: SubrouterProvider, accountID: String) -> String? {
        switch provider {
        case .codex:
            return "cmux sr add"
        case .claude:
            return "cmux sr claude add \(shellQuoted(accountID))"
        default:
            return nil
        }
    }

    /// The command that removes the account from `sr`'s local store, or
    /// `nil` when unsupported. Callers pre-type this into a terminal
    /// without running it — pressing Return is the confirmation.
    public static func removeAccount(provider: SubrouterProvider, accountID: String) -> String? {
        switch provider {
        case .codex:
            return "cmux sr remove \(shellQuoted(accountID))"
        case .claude:
            return "cmux sr claude remove \(shellQuoted(accountID))"
        default:
            return nil
        }
    }

    /// Wraps a value in single quotes for POSIX shells, escaping any
    /// embedded single quotes. Account ids are emails or profile names,
    /// but they cross a shell boundary and must never be interpolated raw.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
