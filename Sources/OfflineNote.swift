import Foundation

/// Lifecycle status of a captured offline note as it moves through the queue.
///
/// The three user-facing states called out in the feature request — pending,
/// sent, and failed — are surfaced directly; ``sending`` is a transient
/// in-flight state that collapses back to ``pending`` if the app is relaunched
/// mid-dispatch (see ``OfflineNotesStore``'s load normalization).
enum OfflineNoteStatus: String, Codable, Sendable, CaseIterable {
    /// Captured locally, waiting to be handed off to an agent (offline, or
    /// queued until the next flush).
    case pending
    /// Hand-off to an agent is in progress.
    case sending
    /// Successfully delivered to an agent.
    case sent
    /// Hand-off failed; the note is preserved and can be retried.
    case failed
}

/// A note captured by the user — typically while offline — and queued so cmux
/// can turn it into an agent task once connectivity is restored.
///
/// Notes are value types persisted as a JSON array so they survive app
/// restarts. Each note records enough state to render its status and support
/// retries without losing the original text.
struct OfflineNote: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    /// Workspace this note was captured in; delivery targets it (not whatever is
    /// active at flush time), so a note never lands in an unrelated workspace.
    var workspaceID: UUID?
    var status: OfflineNoteStatus
    var createdAt: Date
    var updatedAt: Date
    /// When the note was successfully delivered to an agent.
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
