/// Immutable file, location, hunk, and excerpt context for a quick agent note.
struct DiffNoteContext: Identifiable, Sendable, Equatable {
    /// Stable identity for sheet presentation.
    let id: String
    /// Repository-relative changed-file path.
    let path: String
    /// Side-aware selected line.
    let lineReference: DiffNoteLineReference
    /// Canonical `@@ -a,b +c,d @@` header without a section suffix.
    let hunkReference: String
    /// ASCII unified-diff lines included in the prompt.
    let excerpt: String
}
