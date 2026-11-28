public import CmuxHomeCore
import CmuxNextDaemon
import Foundation

nonisolated extension CloudHomeSource {
    // MARK: Threads (cx-59n8.6)

    public func historyPage(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> HistoryPage {
        let (commands, identity, _) = try requireEndpoint()
        let page = try await reply(for: identity) { try await commands.history(conversation.rawValue, before: beforeSeq, limit: limit) }
        return HistoryPage(messages: page.messages.map { CloudHomeMapping.message($0, identity: identity) },
                           threads: page.threads.map { HomeCoreMapping.thread($0, author: identity.toHome) })
    }

    /// ConversationDO's `conversation.thread` through the proxy; a daemon
    /// without `conversation-thread-v1` scans history instead.
    public func thread(of conversation: ConversationID, root: MessageID, after afterSeq: Seq, limit: Int) async throws -> ThreadPage {
        let (commands, identity, _) = try requireEndpoint()
        let page: ConversationThread? = try await reply(for: identity) {
            do {
                return try await commands.thread(conversation.rawValue, root: root.rawValue, after: afterSeq, limit: limit)
            } catch let error where HomeCoreMapping.lacksThreadRead(error) {
                return nil
            }
        }
        guard let page else { return try await scanThread(of: conversation, root: root, after: afterSeq, limit: limit) }
        return HomeCoreMapping.threadPage(page, message: { CloudHomeMapping.message($0, identity: identity) }, author: identity.toHome)
    }
}
