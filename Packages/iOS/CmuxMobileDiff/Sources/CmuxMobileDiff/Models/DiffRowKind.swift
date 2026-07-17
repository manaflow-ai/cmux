/// The semantic presentation of a native diff row.
enum DiffRowKind: Sendable, Equatable, Hashable {
    /// A section-owned file heading.
    case fileHeader
    /// An unchanged source line.
    case context
    /// A newly added source line.
    case addition
    /// A removed source line.
    case deletion
    /// A unified-diff hunk heading.
    case hunkHeader
    /// Git's missing-final-newline annotation.
    case noNewline
    /// A range of context that can be fetched lazily.
    case expansionGap
    /// A binary-file explanation.
    case binary
    /// A gated large diff.
    case largeDiff
    /// A rename or copy without textual patch rows.
    case renameOnly
    /// A patch beyond the host's absolute rendering cap.
    case tooLarge
    /// A transient loading row.
    case loading
    /// A file-scoped failure row.
    case error
}
