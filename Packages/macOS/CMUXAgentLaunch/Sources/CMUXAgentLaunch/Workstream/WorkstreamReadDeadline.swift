/// Signals that a recovery pass stopped before consuming its full page.
enum WorkstreamReadDeadline: Error {
    case exceeded
    /// A bounded startup-tail pass decoded some rows before the deadline.
    /// The caller must publish those rows and use its original EOF cursor so
    /// every unexamined byte remains reachable by paging.
    case partial(WorkstreamBoundedLatestResult)
}
