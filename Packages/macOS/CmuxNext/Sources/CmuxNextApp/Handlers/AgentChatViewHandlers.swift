import CmuxNextActions
import Foundation

/// View Chat Only (`agentChat.view`, `cmux agent view <chat>`): a Claude Code or Codex chat in a
/// tab that shows it and follows the app that runs it, without running it, until Take Over. The
/// All chats row's View Only item (`chats.watch`) calls the same ``ChatsOpenCoordinator/watch(_:)``.
enum AgentChatViewHandlers {
    static let action: ActionID = "agentChat.view"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind(action, run: { invocation in
            let key = (invocation["key"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard isChatKey(key) else { throw ActionFailure(message: AgentChatViewStrings.notAChat(key)) }
            services.chatsOpener.watch(key)
        })
    }

    /// An index key the opener resolves: `claude-code:<id>` or `codex:<id>`, the families acpmux
    /// can show without running (`hub/watch.rs`).
    static func isChatKey(_ key: String) -> Bool {
        guard key.count <= 512, let colon = key.firstIndex(of: ":") else { return false }
        return ["claude-code", "codex"].contains(String(key[..<colon])) && key.index(after: colon) < key.endIndex
    }
}

enum AgentChatViewStrings {
    static func notAChat(_ key: String) -> String {
        String(format: String(localized: "agentChat.view.notAChat",
                              defaultValue: "%@ is not a Claude Code or Codex chat. Name it as claude-code:<id> or codex:<id>.",
                              table: "Handlers", bundle: .module), key)
    }
}
