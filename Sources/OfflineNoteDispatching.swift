import Foundation

/// Delivers a queued note to an agent. Conformers throw to mark the note
/// ``OfflineNoteStatus/failed`` (the note is preserved and retryable).
///
/// Modeling delivery as a seam keeps ``OfflineNotesStore`` fully testable (the
/// store is exercised against an in-memory fake) and lets the concrete agent
/// hand-off evolve independently of the queue semantics.
@MainActor
protocol OfflineNoteDispatching: AnyObject {
    func dispatch(_ note: OfflineNote) async throws
}
