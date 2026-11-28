// Accounts and CodeRouter (plans/cmux-next/coderouter.md). Titles live in
// AccountsActions.xcstrings. Provider ids match CmuxNextCodeRouter's
// `AIProvider` raw values (a test in the App checks it). No action takes a
// secret as an argument: keys and tokens are pasted in the Accounts screen.

nonisolated enum AccountActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        var actions = [
            ActionDescriptor(
                id: "accounts.show",
                title: text("action.accounts.show", "Accounts…"),
                keywords: ["coderouter", "codex", "chatgpt", "claude", "anthropic", "openai", "api key", "login"],
                category: .cloud, symbol: "person.crop.circle", surfaces: [.palette, .menu], cliName: "accounts show"
            ),
            ActionDescriptor(
                id: "accounts.refresh",
                title: text("action.accounts.refresh", "Refresh Accounts"),
                keywords: ["coderouter", "detect", "sign-in"], category: .cloud, symbol: "arrow.clockwise",
                surfaces: [.palette], cliName: "accounts refresh"
            ),
            ActionDescriptor(
                id: "accounts.reauthenticate",
                title: text("action.accounts.reauthenticate", "Re-authenticate Provider…"),
                keywords: ["coderouter", "login", "codex login", "claude login", "sign in"], category: .cloud,
                symbol: "person.badge.key", surfaces: [.palette], arguments: [providerArgument(linkableOnly: false)],
                cliName: "accounts reauth"
            ),
            ActionDescriptor(
                id: "accounts.connect",
                title: text("action.accounts.connect", "Connect Account to CodeRouter…"),
                keywords: ["coderouter", "link", "share", "agents", "cloud"], category: .cloud, symbol: "link",
                surfaces: [.palette], requires: [.signedIn], arguments: [providerArgument(linkableOnly: true)],
                cliName: "accounts connect"
            ),
            ActionDescriptor(
                id: "accounts.remove",
                title: text("action.accounts.remove", "Remove Account from CodeRouter"),
                keywords: ["coderouter", "unlink", "delete"], category: .cloud, symbol: "link.badge.plus",
                surfaces: [.palette], requires: [.signedIn],
                arguments: [ActionArgument(name: "account", title: text("argument.account", "Account ID"), kind: .string)],
                cliName: "accounts remove", destructive: true
            ),
        ]
        // Connect and remove are CodeRouter round trips: the CLI waits for
        // the outcome and exits non-zero when it failed.
        for index in actions.indices where ["accounts.connect", "accounts.remove"].contains(actions[index].id.rawValue) {
            actions[index].waitsForResult = true
        }
        return actions
    }

    /// Provider ids and product names (never localized).
    static let accountProviders: [(id: String, name: String, linkable: Bool)] = [
        ("codex", "ChatGPT / Codex", true), ("openai", "OpenAI API", true), ("claude", "Claude Code", true),
        ("anthropic", "Anthropic API", true), ("gemini", "Gemini", false), ("openrouter", "OpenRouter", true),
        ("groq", "Groq", false), ("xai", "xAI", false), ("mistral", "Mistral", false), ("deepseek", "DeepSeek", false),
        ("bedrock", "Amazon Bedrock", true), ("vertex", "Google Vertex AI", false), ("copilot", "GitHub Copilot", false),
    ]

    private static func providerArgument(linkableOnly: Bool) -> ActionArgument {
        let cases = accountProviders.filter { !linkableOnly || $0.linkable }.map { ActionEnumCase(value: $0.id, title: $0.name) }
        return ActionArgument(name: "provider", title: text("argument.provider", "Provider"), kind: .enumeration(cases))
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AccountsActions", bundle: .module)
    }
}
