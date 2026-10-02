import Foundation

// The owner stamps every write with the connection's principal: an unbound
// trusted local connection is `user_local`; a connection becomes an agent by
// binding with a token the local user minted (plans/cmux-next/home.md section 2).

/// `conversation-agent-token`: mints the credential of agent `participant`.
public struct ConversationAgentTokenRequest: DaemonRequest {
    public typealias Response = ConversationAgentToken
    public static let command = "conversation-agent-token"
    public var participant: String
    public init(participant: String) { self.participant = participant }
}

/// `conversation-bind`: binds the connection to agent `participant`.
public struct ConversationBindRequest: DaemonRequest {
    public typealias Response = ConversationAgentToken
    public static let command = "conversation-bind"
    public var participant: String
    public var token: String
    public init(participant: String, token: String) {
        self.participant = participant
        self.token = token
    }
}

/// The result of both commands (`token` only from `conversation-agent-token`).
public struct ConversationAgentToken: Decodable, Sendable, Equatable {
    public var participant: String
    public var token: String?
}
