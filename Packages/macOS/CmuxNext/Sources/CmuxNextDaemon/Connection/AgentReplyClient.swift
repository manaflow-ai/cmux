import Foundation

/// What `agent.message.send` stored for a reply in place.
public struct AgentReplySent: Decodable, Sendable, Equatable {
    public var id: String
    public var threadId: String
    /// Who the daemon says sent it (`acp:<session>` for the credential's chat).
    public var sender: String

    enum CodingKeys: String, CodingKey {
        case id, sender
        case threadId = "thread_id"
    }
}

/// A reply in place the daemon stored as someone else than the chat it was minted for (a launch
/// key rotated between the mint and the send makes the credential count as none).
public struct AgentReplyWrongSender: Error, Equatable, Sendable {
    public var sender: String
}

extension StateResourceClient {
    private struct Minted: Decodable {
        var credential: String
    }

    /// The agent pane's reply in place (CmuxNextAgentPane `AgentPaneAgentReply`), sent as ACP
    /// session `acpSession`, the chat that answers: `credential.mint {acp_session}` on this
    /// connection (only the verified app may mint, cmux-tui-core `check_credential_owner`), then
    /// `agent.message.send {in_reply_to, thread_id, body, sender_name}` under that credential and
    /// `idempotencyKey`. No recipient: the daemon sends a reply to its parent's sender, and checks
    /// that the parent exists, that `threadId` is its thread and that the chat takes part in it.
    /// The credential stays in this call; it is never stored, returned or logged. A reply the daemon
    /// stored as anyone but `acp:<acpSession>` throws ``AgentReplyWrongSender`` (fail closed).
    public func sendAgentReply(asACPSession acpSession: String, senderName: String?, inReplyTo: String, threadId: String,
                               body: String, idempotencyKey: String) async throws -> AgentReplySent {
        let mint: [String: JSONValue] = ["acp_session": .string(acpSession)]
        let minted = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "credential.mint", params: mint, idempotencyKey: nil)
        }, as: Minted.self)
        var fields: [String: JSONValue] = ["in_reply_to": .string(inReplyTo), "thread_id": .string(threadId), "body": .string(body)]
        if let senderName { fields["sender_name"] = .string(senderName) }
        let params = fields
        let credential = minted.credential
        let sent = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "agent.message.send", params: params, idempotencyKey: idempotencyKey,
                                    credential: credential)
        }, as: ResourceMutationResult<AgentReplySent>.self).value
        guard sent.sender == "acp:\(acpSession)" else { throw AgentReplyWrongSender(sender: sent.sender) }
        return sent
    }
}
