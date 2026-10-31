/// The git change painted beside one File Preview gutter line.
///
/// Values come from ``FilePreviewGitLineDiff`` and are keyed by the 1-based
/// line number they decorate.
public enum FilePreviewGitLineChange: Sendable, Equatable {
    /// The line does not exist in the git base.
    case added
    /// The line replaced one or more git base lines.
    case modified
    /// Git base lines were deleted immediately above this line.
    case removed
    /// Git base lines were deleted below this line, which is the last line.
    case removedAtEnd
}
