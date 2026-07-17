/// Granularity requested by a diff-note entry point.
enum DiffNoteSelectionScope: Sendable, Equatable {
    /// Includes only the pressed source line.
    case line
    /// Includes every source row in the selected hunk.
    case hunk
}
