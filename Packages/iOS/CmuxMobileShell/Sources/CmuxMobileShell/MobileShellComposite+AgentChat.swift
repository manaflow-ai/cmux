public import CmuxAgentChat
internal import CmuxMobileRPC

/// Agent-chat access for the shell store: surfaces sessions and a
/// conversation event source bound to the current Mac connection.
extension MobileShellComposite {
    /// Cached chat-capable sessions for a workspace, from the last authoritative
    /// pull or push-derived session list. Used by workspace detail views before
    /// their per-view refresh task has reconnected.
    public func cachedChatSessions(workspaceID: String) -> [ChatSessionDescriptor] {
        chatSessionSnapshotsByWorkspaceID[workspaceID] ?? []
    }

    /// Replaces the cached chat-session snapshot for a workspace. Call only when
    /// data came from an authoritative pull or from the live session event stream,
    /// not when the transport is unavailable.
    public func rememberChatSessions(
        _ sessions: [ChatSessionDescriptor],
        workspaceID: String
    ) {
        chatSessionSnapshotsByWorkspaceID[workspaceID] = sessions
    }

    /// A chat event source over the current connection, or `nil` when not
    /// connected. Construct one ``ChatConversationStore`` per opened
    /// conversation from this.
    public func makeChatEventSource() -> MobileChatEventSource? {
        guard let client = chatRPCClient() else { return nil }
        return MobileChatEventSource(client: client, supportsArtifacts: supportsChatArtifacts)
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

    /// Returns whether a chat-session list failure means the connected Mac does
    /// not support chat RPCs, rather than a transient transport failure.
    public func chatSessionListFailureMeansUnsupported(_ error: any Error) -> Bool {
        guard case let MobileShellConnectionError.rpcError(code, message) = error else {
            return false
        }
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedCode,
           ["method_not_found", "not_found", "unknown_method", "unsupported_method"].contains(normalizedCode) {
            return true
        }
        return normalizedMessage.contains("unknown method")
            || normalizedMessage.contains("method not found")
            || normalizedMessage.contains("unsupported method")
    }

    /// The connected RPC client, for chat use only.
    private func chatRPCClient() -> MobileCoreRPCClient? {
        guard connectionState == .connected else { return nil }
        return remoteClientForAgentChat
    }
}
