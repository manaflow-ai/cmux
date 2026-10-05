import Foundation

/// An account type CodeRouter routes, named as `coderouter accounts --json`
/// reports it in each account's `provider`.
struct CoderouterProvider: Hashable {
    let id: String

    static let codex = CoderouterProvider(id: "codex")
    static let claude = CoderouterProvider(id: "claude")
    static let opencode = CoderouterProvider(id: "opencode")

    /// The types `cr add <type>` adds, in sidebar order. Each keeps its group
    /// and New Account row even before the team has an account of that type.
    static let addable: [CoderouterProvider] = [.codex, .claude, .opencode]

    var canAdd: Bool { Self.addable.contains(self) }

    var title: String {
        switch id {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "opencode": return "OpenCode"
        default: return id.capitalized
        }
    }

    var newAccountTitle: String {
        String(format: String(localized: "coderouter.newAccount", defaultValue: "New %@ Account"), title)
    }

    /// The command a New Account row submits in a terminal; the CLI adds the
    /// account to its active organization, which the sidebar reads.
    var addCommand: String { "cmux cr add \(id)" }
}

/// What the Cloud tree's CodeRouter section shows: the selected team's
/// accounts and whether a refresh is running.
struct CloudTreeCoderouterSection: Equatable {
    var accounts: [CloudTreeNode.CoderouterAccount] = []
    var isRefreshing = false
}
