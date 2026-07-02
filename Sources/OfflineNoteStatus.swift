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
