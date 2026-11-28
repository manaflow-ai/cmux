import Foundation

// The owner stamps every write with the connection's principal: an unbound
// trusted local connection is `user_local`; a connection becomes an agent by
// binding with a token the local user minted (plans/cmux-next/home.md section 2).

/// The result of both commands (`token` only from `conversation-agent-token`).
public struct ConversationAgentToken: Decodable, Sendable, Equatable {
    public var participant: String
    public var token: String?
}
