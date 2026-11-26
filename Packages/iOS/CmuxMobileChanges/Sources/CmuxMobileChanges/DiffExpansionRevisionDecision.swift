/// The action to take after comparing diff and current-content revisions.
public enum DiffExpansionRevisionDecision: Sendable, Equatable {
    /// Use the fetched current lines for hidden-context expansion.
    case accept
    /// Discard the fetched lines and reload the diff before expanding.
    case reloadDiff
}
