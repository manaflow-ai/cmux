import Foundation

/// A note captured by the user — typically while offline — and queued so cmux
/// can stage it in the workspace composer once connectivity is restored.
///
/// Notes are value types persisted as a JSON array so they survive app
/// restarts. Each note records enough state to render its status and support
/// retries without losing the original text.
struct OfflineNote: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    /// Workspace this note was captured in; staging targets it (not whatever is
    /// active at flush time), so a note never lands in an unrelated workspace.
    var workspaceID: UUID?
    var status: OfflineNoteStatus
    var createdAt: Date
    var updatedAt: Date
    /// Legacy timestamp for notes marked sent by older builds.
    var sentAt: Date?
    /// Number of dispatch attempts so far (drives retry display / backoff).
    var attemptCount: Int
    /// Human-readable reason for the most recent failure, if any.
    var lastError: String?

    init(
        id: UUID = UUID(),
        text: String,
        workspaceID: UUID? = nil,
        status: OfflineNoteStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sentAt: Date? = nil,
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.text = text
        self.workspaceID = workspaceID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sentAt = sentAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}
