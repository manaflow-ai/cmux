/// A workspace copy selected for the merged restore generation.
public enum CrashWorkspaceMergeSelection: Equatable, Sendable {
    /// Keep a workspace from the preferred window at its original index.
    case preferred(Int)
    /// Keep a workspace from the supplemental window at its original index.
    case supplemental(Int)
}
