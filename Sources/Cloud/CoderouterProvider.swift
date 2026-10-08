import Foundation

/// An account type CodeRouter routes, named exactly as `coderouter accounts
/// --json` reports it in each account's `provider` (the server's provider names).
struct CoderouterProvider: Hashable {
    let id: String

    static let codex = CoderouterProvider(id: "codex")
    static let claude = CoderouterProvider(id: "claude")
    static let opencodeGo = CoderouterProvider(id: "opencode-go")
    static let openaiAPIKey = CoderouterProvider(id: "openai-apikey")
    static let openrouterAPIKey = CoderouterProvider(id: "openrouter-apikey")

    /// The types `cr add <type>` adds, in sidebar order. Each keeps its group
    /// even before the team has an account of that type; the section header's
    /// Add menu owns account creation.
    /// API-key types have no `cr add` flow yet; their accounts still list.
    static let addable: [CoderouterProvider] = [.codex, .claude, .opencodeGo]

    var canAdd: Bool { Self.addable.contains(self) }

    var title: String {
        switch id {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "opencode-go": return "OpenCode Go"
        case "openai-apikey": return "OpenAI API Key"
        case "openrouter-apikey": return "OpenRouter API Key"
        default: return id.capitalized
        }
    }

    var newAccountTitle: String {
        String(format: String(localized: "coderouter.newAccount", defaultValue: "Add %@ account"), title)
    }

    /// The command an Add Account menu submits in a terminal. An explicit
    /// organization keeps the account attached to the team whose row was
    /// clicked even if another terminal changes CodeRouter's active scope.
    var addCommand: String {
        switch id {
        case "opencode-go": return "cmux cr add opencode"
        default: return "cmux cr add \(id)"
        }
    }

    /// The shell command a New Account row runs for one team. `scope` is the
    /// mechanism the last account read proved the CLI supports:
    /// `CODEROUTER_TEAM_ID` for one invocation, `--team`, or (older CLIs) an
    /// `org switch` inside a private copy of the config.
    func addCommand(
        for organizationID: String?,
        scope: CoderouterTeamScope = .isolatedConfiguration,
        cmuxExecutable: String = "cmux"
    ) -> String {
        let cli = cmuxExecutable == "cmux" ? "cmux" : Self.shellQuote(cmuxExecutable)
        let provider = id == "opencode-go" ? "opencode" : id
        let addCommand = "\(cli) cr add \(provider)"
        guard let organizationID = organizationID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !organizationID.isEmpty else {
            return addCommand
        }
        let quotedOrganization = Self.shellQuote(organizationID)
        switch scope {
        case .teamOverride:
            // Also pass --team: if the terminal's `cmux cr` resolves an older
            // CLI that ignores the variable, the add still targets this team
            // (or fails loudly) instead of the saved default organization.
            return "\(CoderouterTeamEnvironment.shellAssignment(teamID: organizationID)) \(addCommand) --team \(quotedOrganization)"
        case .teamOption:
            return "\(addCommand) --team \(quotedOrganization)"
        case .isolatedConfiguration:
            break
        }
        // cmux bundles a pinned CodeRouter binary, while a user's PATH may
        // resolve a different version. Run the legacy org-switch + add flow in
        // a temporary copy of the config so every supported CLI version gets
        // the selected team and the user's shared active organization is never
        // changed by a sidebar click. A successful team-scoped account read
        // selects the direct command above for newer CLIs.
        let script = "tmp=$(mktemp -d \"${TMPDIR:-/tmp}/cmux-coderouter-add.XXXXXX\") || exit 1; cleanup(){ rm -rf \"$tmp\"; }; trap cleanup EXIT INT TERM; source_root=\"${CODEROUTER_DATA_DIR:-$HOME/Library/Application Support}\"; source_config=\"$source_root/coderouter/config.json\"; if [ ! -f \"$source_config\" ]; then echo 'CodeRouter is not signed in on this Mac.' >&2; exit 1; fi; if ! mkdir -p \"$tmp/coderouter\"; then exit 1; fi; if ! cp \"$source_config\" \"$tmp/coderouter/config.json\"; then exit 1; fi; result=0; if CODEROUTER_DATA_DIR=\"$tmp\" \(cli) cr org switch \(quotedOrganization); then CODEROUTER_DATA_DIR=\"$tmp\" \(addCommand) || result=$?; else result=$?; fi; exit \"$result\""
        return "/bin/sh -c \(Self.shellQuote(script))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What the Cloud tree's CodeRouter section shows: the selected team's
/// accounts and whether a refresh is running.
struct CloudTreeCoderouterSection: Equatable {
    var accounts: [CloudTreeNode.CoderouterAccount] = []
    var isRefreshing = false
}
