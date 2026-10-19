import Foundation

/// What the consent panel shows for one agent's cookie import (a value: the
/// panel holds no store). The requester is a reference to the agent (its chat
/// or terminal tab, by name), never a link: a click reveals that tab in cmux.
struct CookieImportRequest: Sendable, Equatable {
    /// Who asked, as the run's caller names itself (`caller.agent_session` or `caller.terminal_id`).
    struct Requester: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case agentChat
            case terminal
            /// No chat or terminal named itself (a script outside cmux).
            case unknown
        }

        var kind: Kind
        /// The tab's title ("a49 · cookie import"), empty for `unknown`.
        var name: String
        /// The workspace that holds the tab, nil when unknown.
        var workspace: String?
        /// The tab to reveal on "Show Agent Chat" (`tab.focus` target), nil when none.
        var tabID: String?
        /// The agent's latest reply, one line (acpmux's chat preview), nil when unknown.
        var latestMessage: String?

        /// The reference shown on the panel ("Agent chat “a49 · …”").
        var reference: String {
            switch kind {
            case .agentChat: CookieImportStrings.agentChat(name)
            case .terminal: CookieImportStrings.terminal(name)
            case .unknown: CookieImportStrings.unknownRequester
            }
        }
    }

    var requester: Requester
    /// The agent's own words (`--reason`), shown as given.
    var reason: String
    /// "Google Chrome · Work".
    var source: String
    /// Whether the source is Safari (Full Disk Access instead of a Keychain prompt).
    var sourceIsSafari: Bool
    /// The `--domain` hosts; empty means every cookie of the profile.
    var domains: [String]
    /// The cmux browser profile the cookies go into, by name.
    var target: String
}

/// The person's answer on the consent panel.
enum CookieImportAnswer: Sendable, Equatable {
    case allow
    case deny
    /// No answer within the panel's limit; treated as Deny.
    case timedOut
}
