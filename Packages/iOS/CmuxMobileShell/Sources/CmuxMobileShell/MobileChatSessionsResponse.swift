public import CmuxAgentChat

/// Result payload of `mobile.chat.sessions`.
public struct MobileChatSessionsResponse: Sendable, Equatable, Codable {
    /// The chat-capable sessions the host reported.
    public let sessions: [ChatSessionDescriptor]

    /// Creates a response.
    ///
    /// - Parameter sessions: The chat-capable sessions.
    public init(sessions: [ChatSessionDescriptor]) {
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
    }
}
