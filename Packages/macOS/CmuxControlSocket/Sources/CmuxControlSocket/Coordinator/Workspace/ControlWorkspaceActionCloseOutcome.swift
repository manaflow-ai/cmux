/// The post-mutation snapshot of a `workspace.action` close
/// (`close_others` / `close_above` / `close_below`).
public enum ControlWorkspaceActionCloseOutcome: Sendable, Equatable {
    /// The workspace could not be located in its TabManager (legacy `not_found`,
    /// reachable only for `above` / `below`, which re-read its index before
    /// gathering candidates; `others` never produces this).
    case notFound
    /// The close applied; carries the count of workspaces actually closed
    /// (legacy `closed`).
    case closed(Int)
}
