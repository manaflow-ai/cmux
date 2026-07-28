/// Authoritative session state sent after a connection opens or resynchronizes.
public struct ShareSessionSnapshot: Codable, Equatable, Sendable {
    /// Wire protocol version.
    public var proto: Int

    /// Shared workspace metadata.
    public var shared: [ShareSharedWorkspace]

    /// Current layouts for shared workspaces.
    public var layouts: [ShareWorkspaceLayout]

    /// Approved and connected participant state.
    public var participants: [ShareParticipant]

    /// Bounded chat history.
    public var chat: [ShareChatMessage]

    /// Identity of the receiving connection.
    public var you: ShareSelfIdentity

    /// Creates a complete session snapshot.
    public init(
        proto: Int,
        shared: [ShareSharedWorkspace],
        layouts: [ShareWorkspaceLayout],
        participants: [ShareParticipant],
        chat: [ShareChatMessage],
        you: ShareSelfIdentity
    ) {
        self.proto = proto
        self.shared = shared
        self.layouts = layouts
        self.participants = participants
        self.chat = chat
        self.you = you
    }
}
