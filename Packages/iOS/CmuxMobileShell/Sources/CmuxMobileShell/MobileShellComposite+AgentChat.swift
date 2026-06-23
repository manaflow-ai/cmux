public import CmuxAgentChat
internal import CmuxMobileRPC

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

    /// The connected RPC client, for chat use only.
    private func chatRPCClient() -> MobileCoreRPCClient? {
        guard connectionState == .connected else { return nil }
        return remoteClientForAgentChat
    }
}
