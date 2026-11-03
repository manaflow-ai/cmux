public import CmuxNextActions
import Foundation

/// Who asked for a cookie import, as the run's caller names itself
/// (`caller.agent_session` or `caller.terminal_id`).
public struct CookieImportRequester: Sendable, Equatable {
    /// What kind of tab asked.
    public enum Kind: Sendable, Equatable {
        /// An agent chat tab (`caller.agent_session`).
        case agentChat
        /// A terminal tab (`caller.terminal_id`).
        case terminal
        /// No chat or terminal named itself (a script outside cmux).
        case unknown
    }

    /// What kind of tab asked.
    public var kind: Kind
    /// The tab's title ("a49 · cookie import"), empty for `unknown`.
    public var name: String
    /// The workspace that holds the tab, nil when unknown.
    public var workspace: String?
    /// The tab to reveal on "Show Agent Chat" (`tab.focus` target), nil when none.
    public var tabID: String?
    /// The agent's latest reply, one line (acpmux's chat preview), nil when unknown.
    public var latestMessage: String?

    /// Creates a requester.
    public init(kind: Kind, name: String, workspace: String? = nil, tabID: String? = nil, latestMessage: String? = nil) {
        self.kind = kind
        self.name = name
        self.workspace = workspace
        self.tabID = tabID
        self.latestMessage = latestMessage
    }

    /// The name a Chief's run shows (`caller.home_chat`): its turn's session is temporary and has
    /// no tab, so the panel names the Chief and reveals Home's chat (#32960).
    static let chiefName = "Chief"

    /// Finds who asked among the open tabs: the agent chat whose session is
    /// `caller.agent_session`, else Home's chat for a Chief's turn (`caller.home_chat`), else
    /// that session's acpmux chat, else the terminal whose id is `caller.terminal_id`.
    ///
    /// - Parameters:
    ///   - invocation: The run; its caller fields name the requester.
    ///   - tabs: Every open tab, in workspace order.
    ///   - chat: The acpmux chat of a session (title and latest reply), nil when unknown.
    public init(_ invocation: ActionInvocation, among tabs: [CookieImportCandidate],
                chat: (String) -> (title: String?, preview: String?)?) {
        let session = invocation.callerAgentSession
        let latest = session.flatMap(chat)
        if let session, let found = tabs.first(where: { $0.agentSession == session }) {
            self.init(kind: .agentChat, name: found.title, workspace: found.workspace, tabID: found.tabID,
                      latestMessage: latest?.preview)
        } else if invocation.callerHomeChat {
            let home = tabs.first(where: \.isHomeChat)
            self.init(kind: .agentChat, name: Self.chiefName, workspace: home?.workspace, tabID: home?.tabID,
                      latestMessage: latest?.preview)
        } else if let session {
            self.init(kind: .agentChat, name: latest?.title ?? session, latestMessage: latest?.preview)
        } else if let terminal = invocation.callerTerminal, let found = tabs.first(where: { $0.terminalIDs.contains(terminal) }) {
            self.init(kind: .terminal, name: found.title, workspace: found.workspace, tabID: found.tabID)
        } else {
            self.init(kind: .unknown, name: "")
        }
    }

    /// The reference shown on the panel ("Agent chat “a49 · …”").
    var reference: String {
        switch kind {
        case .agentChat: CookieImportStrings.agentChat(name)
        case .terminal: CookieImportStrings.terminal(name)
        case .unknown: CookieImportStrings.unknownRequester
        }
    }
}
