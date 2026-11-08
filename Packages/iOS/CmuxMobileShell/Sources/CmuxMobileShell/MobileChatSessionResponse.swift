public import CmuxAgentChat

/// Result payload of `mobile.chat.session` (single-session snapshot pull).
public struct MobileChatSessionResponse: Sendable, Equatable, Codable {
    /// The authoritative current descriptor for the requested session,
    /// carrying the host's monotonic `version` for reconciliation.
    public let session: ChatSessionDescriptor

    /// Creates a response.
    ///
    /// - Parameter session: The session descriptor.
    public init(session: ChatSessionDescriptor) {
        self.session = session
    }

    private enum CodingKeys: String, CodingKey {
        case session
    }
}
