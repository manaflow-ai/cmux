public import CmuxAgentChat
internal import CmuxMobileRPC
import Foundation

/// Agent-chat access for the shell store: surfaces sessions and a
/// conversation event source bound to the current Mac connection.
extension MobileShellComposite {
    /// A chat event source over the current connection, or `nil` when not
    /// connected. Construct one ``ChatConversationStore`` per opened
    /// conversation from this.
    public func makeChatEventSource() -> MobileChatEventSource? {
        guard let client = chatRPCClient() else { return nil }
        return MobileChatEventSource(client: client)
    }

    /// Lists chat-capable agent sessions on the connected Mac.
    ///
    /// - Parameter workspaceID: Restrict to one workspace, or `nil`.
    /// - Returns: Session descriptors, most recent first; empty when not
    ///   connected or the Mac predates chat support.
    public func chatSessions(workspaceID: String?) async -> [ChatSessionDescriptor] {
        guard let source = makeChatEventSource() else { return [] }
        return (try? await source.sessions(workspaceID: workspaceID)) ?? []
    }

    /// The highest message seq the user has seen in a session, persisted
    /// across launches so reopening a chat shows an unread divider for
    /// messages that arrived since. `nil` when never opened.
    ///
    /// - Parameter sessionID: The chat session id.
    public func chatLastReadSeq(sessionID: String) -> Int? {
        let value = UserDefaults.standard.integer(forKey: Self.chatReadCursorKey(sessionID))
        return value == 0 ? nil : value
    }

    /// Records the highest seen seq for a session (call when the chat
    /// closes). Monotonic: never lowers a stored cursor.
    ///
    /// - Parameters:
    ///   - seq: The newest message seq the user has now seen.
    ///   - sessionID: The chat session id.
    public func setChatLastReadSeq(_ seq: Int, sessionID: String) {
        guard seq > 0 else { return }
        let existing = chatLastReadSeq(sessionID: sessionID) ?? 0
        guard seq > existing else { return }
        UserDefaults.standard.set(seq, forKey: Self.chatReadCursorKey(sessionID))
    }

    private static func chatReadCursorKey(_ sessionID: String) -> String {
        "chat.lastReadSeq.\(sessionID)"
    }

    /// The connected RPC client, for chat use only.
    private func chatRPCClient() -> MobileCoreRPCClient? {
        guard connectionState == .connected else { return nil }
        return remoteClientForAgentChat
    }
}
