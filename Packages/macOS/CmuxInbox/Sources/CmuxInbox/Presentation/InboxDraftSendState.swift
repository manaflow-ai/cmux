import Foundation

/// Send-button state for a selected draft.
public enum InboxDraftSendState: String, Codable, Equatable, Sendable {
    /// No draft exists yet.
    case noDraft
    /// Draft exists but cannot be sent because it is empty.
    case emptyDraft
    /// Draft is ready for explicit user approval.
    case requiresApproval
    /// Draft was already sent.
    case sent
    /// Draft failed to send.
    case failed
}
