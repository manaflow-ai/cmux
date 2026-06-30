public import Foundation

/// A text note captured on mobile while the Mac connection is unavailable.
///
/// Notes are replayed into the originally selected terminal when the Mac comes
/// back online. The status is persisted so relaunches can show whether a note is
/// still waiting, currently sending, already sent, or needs a retry.
public struct OfflineAgentNote: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending
        case sending
        case sent
        case failed
    }

    public var id: UUID
    public var text: String
    public var workspaceID: String?
    public var terminalID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var sentAt: Date?
    public var status: Status
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        text: String,
        workspaceID: String?,
        terminalID: String?,
        createdAt: Date,
        updatedAt: Date,
        sentAt: Date? = nil,
        status: Status = .pending,
        lastError: String? = nil
    ) {
        self.id = id
        self.text = text
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sentAt = sentAt
        self.status = status
        self.lastError = lastError
    }
}
