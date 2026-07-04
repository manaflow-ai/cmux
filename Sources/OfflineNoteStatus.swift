import Foundation

/// Lifecycle status of a captured offline note as it moves through the queue.
///
/// Pending, staged, sent, and failed are surfaced directly; ``sending`` is a
/// transient in-flight state that collapses back to ``pending`` if the app is
/// relaunched mid-dispatch (see ``OfflineNotesStore``'s load normalization).
enum OfflineNoteStatus: String, Codable, Sendable, CaseIterable {
    /// Captured locally, waiting to be staged for review (offline, or
    /// queued until the next flush).
    case pending
    /// Composer staging is in progress.
    case sending
    /// Staged in the workspace composer for the user to review and submit.
    case staged
    /// Legacy state for notes marked sent by older builds.
    case sent
    /// Staging failed; the note is preserved and can be retried.
    case failed
}
