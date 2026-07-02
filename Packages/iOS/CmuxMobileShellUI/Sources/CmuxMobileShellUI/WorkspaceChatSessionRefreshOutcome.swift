import CmuxAgentChat
import Foundation

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

extension ChatSessionEventFrame {
    func shouldPullAuthoritativeSnapshotForIgnoredWorkspaceFrame(
        workspaceID: String,
        selectedTerminalID: String?,
        cachedChatToggleTerminalID: String?
    ) -> Bool {
        guard case .descriptorChanged(let descriptor) = event,
              descriptor.workspaceID != workspaceID,
              let terminalID = descriptor.terminalID else {
            return false
        }
        return terminalID == selectedTerminalID || terminalID == cachedChatToggleTerminalID
    }
}

extension Collection where Element == ChatSessionDescriptor {
    func replacementSessionIDForPinnedChat(
        pinnedID: String,
        cachedTerminalID: String?
    ) -> String? {
        let pinned = first { $0.id == pinnedID }
        guard pinned == nil || pinned?.state == .ended else { return nil }
        let terminalID = pinned?.terminalID ?? cachedTerminalID
        guard let terminalID else { return nil }
        return filter { $0.terminalID == terminalID && $0.id != pinnedID && $0.state != .ended }
            .max { ($0.lastActivityAt ?? .distantPast) < ($1.lastActivityAt ?? .distantPast) }?
            .id
    }
}
