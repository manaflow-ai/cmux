/// The semantic role of one rendered unified-diff line.
public enum DiffLineKind: Sendable, Equatable {
    /// An unchanged line present on both sides.
    case context
    /// A line present only in the new file.
    case addition
    /// A line present only in the old file.
    case removal
    /// A unified-diff hunk boundary beginning with `@@`.
    case hunkHeader
    /// Git's marker that the preceding changed line has no trailing newline.
    case noNewlineMarker
}
