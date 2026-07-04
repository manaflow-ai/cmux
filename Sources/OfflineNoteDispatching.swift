import Foundation

/// Stages a queued note for user review. Conformers throw to mark the note
/// ``OfflineNoteStatus/failed`` (the note is preserved and retryable).
///
/// Modeling staging as a seam keeps ``OfflineNotesStore`` fully testable (the
/// store is exercised against an in-memory fake) and lets the concrete agent
/// staging behavior evolve independently of the queue semantics.
@MainActor
protocol OfflineNoteDispatching: AnyObject {
    func dispatch(_ note: OfflineNote) async throws
}
