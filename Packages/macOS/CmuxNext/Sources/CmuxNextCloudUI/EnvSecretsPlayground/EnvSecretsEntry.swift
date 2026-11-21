#if DEBUG
import Foundation

/// DEBUG ONLY (Environment Secrets Playground): one sample row of an environment. Sample data only:
/// every value is a made-up `EXAMPLE` string, never a real secret.
struct EnvSecretsEntry: Identifiable {
    /// How an API secret is sent toward its hosts.
    enum Delivery: Equatable {
        case bearer
        case header(String)
        case query(String)
        case basic

        var title: String {
            switch self {
            case .bearer: "Authorization: Bearer"
            case let .header(name): "Header \(name)"
            case let .query(name): "Query ?\(name)="
            case .basic: "Basic auth"
            }
        }

        static let choices: [Delivery] = [.bearer, .header("X-Api-Key"), .query("key"), .basic]
    }

    /// Where a value comes from; the most specific scope wins.
    enum Scope: Int, CaseIterable, Identifiable {
        case team, personal, chat

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .team: "Team"
            case .personal: "Personal"
            case .chat: "Chat"
            }
        }

        var symbol: String {
            switch self {
            case .team: "person.3"
            case .personal: "person"
            case .chat: "bubble.left"
            }
        }

        var caption: String {
            switch self {
            case .team: "Admins edit. Everyone on the team uses it."
            case .personal: "Only you. Never used when a teammate drives your chat."
            case .chat: "Only this chat, until it ends."
            }
        }
    }

    var name: String
    var kind: EnvSecretsKind
    /// The readable value for a Variable; a secret keeps only `last4`.
    var value: String = ""
    var last4: String = ""
    var hosts: [String] = []
    var delivery: Delivery?
    var setBy = "Mia Chen"
    var setAt = "Nov 18, 2:14 PM"
    var version = 1
    var scope: Scope = .team
    /// Why the paste picked this type (shown in review only).
    var reason: String?

    var id: String { name }

    /// The value as the page may show it: the full value for a Variable, the last 4 characters for a secret.
    var shown: String { kind == .variable ? value : "•••• \(last4)" }

    /// One sentence that says where the value can go.
    var sentence: String {
        switch kind {
        case .variable:
            return "Set to \(value) in every chat of this environment."
        case .apiSecret where hosts.isEmpty:
            return "No host yet, so nothing can receive this secret."
        case .apiSecret:
            let list = ListFormatter.localizedString(byJoining: hosts)
            return "Goes only to \(list), sent as \(delivery?.title ?? "a header"). The agent sees a placeholder."
        case .setupSecret:
            return "Only the setup script can read it. It is removed before the agent starts."
        case .envSecret:
            return "In the environment of every chat. The agent can read it; the transcript shows •••• (\(name))."
        }
    }
}
#endif
