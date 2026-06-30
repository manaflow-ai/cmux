import CmuxAgentChat

/// Result of refreshing a workspace's chat-session list.
enum WorkspaceChatSessionRefreshOutcome: Equatable {
    /// The Mac was unavailable, reconnecting, or the refresh failed.
    case unavailable
    /// The Mac returned an authoritative current list.
    case authoritative([ChatSessionDescriptor])

    /// Applies the refresh result without treating transport loss as empty data.
    func applying(to current: [ChatSessionDescriptor]) -> [ChatSessionDescriptor] {
        switch self {
        case .unavailable:
            current
        case .authoritative(let sessions):
            sessions
        }
    }

    /// Whether this result is allowed to invalidate the currently displayed chat.
    var canInvalidateSelection: Bool {
        switch self {
        case .unavailable:
            false
        case .authoritative:
            true
        }
    }
}
