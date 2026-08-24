/// Builders for the `sr` shell commands behind the panel's account
/// management actions (add, re-auth, remove). The panel opens these in a
/// real cmux terminal instead of running them silently: OAuth logins are
/// interactive, and destructive commands stay visible to the user.
public enum SubrouterMaintenanceCommand {
    /// The command that starts an interactive add-account login for the
    /// provider, or `nil` when the provider has no add verb.
    ///
    /// The destination is pinned for this invocation through a provider-aware
    /// `sr` server override. Codex uses `SUBROUTER_CODEX_SERVER`; Claude uses
    /// `SUBROUTER_SERVER`, which its profile upload hook honors without
    /// pretending Claude is a Codex account command.
    public static func addAccount(
        provider: SubrouterProvider,
        target: SubrouterAccountTarget = .local
    ) -> String? {
        switch provider {
        case .codex:
            return scoped("cmux sr add", provider: provider, target: target)
        case .claude:
            return scoped("cmux sr claude add", provider: provider, target: target)
        default:
            return nil
        }
    }

    /// Compatibility overload for callers that already have an optional
    /// registry name; new callers should pass an explicit target.
    @available(*, deprecated, message: "Pass an explicit SubrouterAccountTarget instead.")
    public static func addAccount(
        provider: SubrouterProvider,
        serverName: String?
    ) -> String? {
        addAccount(
            provider: provider,
            target: serverName.map { .server(name: $0) } ?? .local
        )
    }

    /// The command that re-runs the provider's login for an existing account,
    /// or `nil` when the provider has no safe profile-reuse verb. Codex OAuth
    /// can infer the account; the pinned Claude CLI's `add <name>` creates a
    /// profile and therefore is intentionally not exposed as re-auth.
    public static func signIn(
        provider: SubrouterProvider,
        accountID: String,
        target: SubrouterAccountTarget = .local
    ) -> String? {
        switch provider {
        case .codex:
            return scoped("cmux sr add", provider: provider, target: target)
        case .claude:
            return nil
        default:
            return nil
        }
    }

    /// The command that removes the account from `sr`'s local store, or
    /// `nil` when unsupported. Callers pre-type this into a terminal
    /// without running it — pressing Return is the confirmation.
    public static func removeAccount(
        provider: SubrouterProvider,
        accountID: String,
        target: SubrouterAccountTarget = .local
    ) -> String? {
        switch provider {
        case .codex:
            return scoped("cmux sr remove \(shellQuoted(accountID))", provider: provider, target: target)
        case .claude:
            return scoped("cmux sr claude remove \(shellQuoted(accountID))", provider: provider, target: target)
        default:
            return nil
        }
    }

    /// The first-run command: installs the sr CLI when missing, starts the
    /// local daemon, and prints next steps. The panel's "Set up subrouter"
    /// button runs this when the local daemon is unreachable.
    public static var setup: String { "cmux subrouter setup" }

    /// The pre-typed template for pointing `sr` at a hosted subrouter
    /// server instead of the local daemon. Never auto-run: the user
    /// replaces the placeholders and presses Return (`sr server use local`
    /// returns to the local daemon later).
    public static var connectServer: String {
        "cmux sr server add <name> --url <url> --default"
    }

    /// Prefixes an `sr` command with a one-shot destination override.
    private static func scoped(
        _ command: String,
        provider: SubrouterProvider,
        target: SubrouterAccountTarget
    ) -> String {
        let value: String
        switch target {
        case .local:
            value = "local"
        case .server(let name):
            value = shellQuoted(name)
        }
        let environmentKey = provider == .claude
            ? "SUBROUTER_SERVER"
            : "SUBROUTER_CODEX_SERVER"
        return "\(environmentKey)=\(value) \(command)"
    }

    /// Wraps a value in single quotes for POSIX shells, escaping any
    /// embedded single quotes. Account ids are emails or profile names,
    /// but they cross a shell boundary and must never be interpolated raw.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
