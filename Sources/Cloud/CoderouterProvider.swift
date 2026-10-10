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
    /// and New Account row even before the team has an account of that type.
    /// API-key types have no `cr add` flow yet; their accounts still list.
    static let addable: [CoderouterProvider] = [.codex, .claude, .opencodeGo]

    var canAdd: Bool { Self.addable.contains(self) }

    var title: String {
        switch id {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "opencode-go": return "OpenCode"
        case "openai-apikey": return "OpenAI API Key"
        case "openrouter-apikey": return "OpenRouter API Key"
        default: return id.capitalized
        }
    }

    var newAccountTitle: String {
        String(format: String(localized: "coderouter.newAccount", defaultValue: "New %@ Account"), title)
    }

    /// The unscoped command shown in the guide and used by ordinary terminal
    /// users. Sidebar setup uses the scoped overload below.
    var addCommand: String {
        switch id {
        case "opencode-go": return "cmux cr add opencode"
        default: return "cmux cr add \(id)"
        }
    }

    /// Builds the command used by the sidebar for one mapped organization.
    /// Newer CLIs accept `--team`; older ones run the whole switch-and-add
    /// sequence against a temporary copy of the CodeRouter config.
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
        case .teamOption:
            return "\(addCommand) --team \(quotedOrganization)"
        case .isolatedConfiguration:
            // Keep the user's saved org untouched when an older CLI has no
            // team option. The temporary config is deleted on every exit.
            let script = "tmp=$(mktemp -d \"${TMPDIR:-/tmp}/cmux-coderouter-add.XXXXXX\") || exit 1; cleanup(){ rm -rf \"$tmp\"; }; trap cleanup EXIT INT TERM; source_root=\"${CODEROUTER_DATA_DIR:-$HOME/Library/Application Support}\"; source_config=\"$source_root/coderouter/config.json\"; if [ ! -f \"$source_config\" ]; then echo 'This account is not signed in on this Mac.' >&2; exit 1; fi; if ! mkdir -p \"$tmp/coderouter\"; then exit 1; fi; if ! cp \"$source_config\" \"$tmp/coderouter/config.json\"; then exit 1; fi; result=0; if CODEROUTER_DATA_DIR=\"$tmp\" \(cli) cr org switch \(quotedOrganization); then CODEROUTER_DATA_DIR=\"$tmp\" \(addCommand) || result=$?; else result=$?; fi; exit \"$result\""
            return "/bin/sh -c \(Self.shellQuote(script))"
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The local terminal launch used by a New Account row. Account setup is
/// interactive, so it always owns a fresh focused terminal instead of writing
/// into whichever terminal happens to be selected (which may be an agent TUI).
struct CoderouterAccountTerminalLaunch: Equatable {
    let command: [String]
    let name: String
    let focus: Bool

    init(provider: CoderouterProvider) {
        command = ["sh", "-lc", provider.addCommand]
        name = "CodeRouter"
        focus = true
    }
}

/// What the Cloud tree's CodeRouter section shows: the selected team's
/// accounts and whether a refresh is running.
struct CloudTreeCoderouterSection: Equatable {
    var accounts: [CloudTreeNode.CoderouterAccount] = []
    var isRefreshing = false
}
