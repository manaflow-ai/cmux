import Foundation

/// Local lifecycle state for a reply draft.
public enum InboxDraftStatus: String, Codable, CaseIterable, Sendable, Hashable {
    /// The draft is editable and has not been sent.
    case editing
    /// The user explicitly approved the send and the connector is sending it.
    case approved
    /// The connector reported the reply as sent.
    case sent
    /// The connector rejected or failed the send.
    case failed
}
