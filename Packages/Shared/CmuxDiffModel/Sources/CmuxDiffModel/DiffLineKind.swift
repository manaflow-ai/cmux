/// The semantic kind of one rendered unified-diff line.
public enum DiffLineKind: String, Sendable, Equatable {
    /// A context line present on both sides of the diff.
    case context
    /// A line added in the new file.
    case addition
    /// A line deleted from the old file.
    case deletion
}
