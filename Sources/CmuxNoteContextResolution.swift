import Foundation

/// Result of resolving "which note does this caller mean" from its
/// surface/workspace links. Drives context-aware `note list` ordering and the
/// `note here` resolver. See [[issue-4331-note-surface-type]].
struct CmuxNoteContextResolution: Sendable {
    /// Notes ordered for display: surface-linked first (most-recently-updated
    /// first within each group), then workspace-linked, then unlinked.
    var orderedNotes: [CmuxNoteRecord]
    /// Link classification keyed by note id (absent = not linked to caller).
    var linkByNoteId: [String: CmuxNoteContextLink]
    /// Best contextual match: most-recent surface-linked note, else
    /// most-recent workspace-linked note, else nil.
    var resolvedNoteId: String?

    func link(for note: CmuxNoteRecord) -> CmuxNoteContextLink? {
        linkByNoteId[note.id]
    }
}
