public import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

extension DaemonService {
    /// The agent pane's reply in place, sent as its chat's cmux agent message on this daemon
    /// (``AgentPaneAgentReply``, `StateResourceClient.sendAgentReply`).
    public func sendAgentReply(_ reply: AgentPaneAgentReply) async throws -> AgentPaneAgentReply.Stored {
        guard let connection else { throw AgentPaneAgentReply.Failure.unavailable }
        do {
            let sent = try await connection.state.sendAgentReply(
                asACPSession: reply.session, senderName: reply.senderName, inReplyTo: reply.replyTo,
                threadId: reply.threadId, body: reply.text, idempotencyKey: reply.idempotencyKey)
            return AgentPaneAgentReply.Stored(id: sent.id, threadId: sent.threadId)
        } catch {
            logger.error("agent pane reply in place refused: \(String(describing: error), privacy: .private)")
            throw error
        }
    }
}
