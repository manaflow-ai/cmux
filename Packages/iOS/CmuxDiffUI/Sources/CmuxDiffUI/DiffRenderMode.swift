/// The visual layout used to render a diff body.
public enum DiffRenderMode: String, Sendable, CaseIterable, Hashable {
    /// A single stream with old and new line-number gutters.
    case unified
    /// Side-by-side old and new code columns with aligned changes.
    case split
}
