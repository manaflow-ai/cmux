/// What a read of one entry by its id found (`history.open`).
public nonisolated enum HistoryLookup: Sendable {
    case found(HistoryEntry)
    /// The id is not among the entries read and its kind's entries are not complete yet
    /// (``DaemonHistoryList/isStillLoading(id:)``): the entry is not known, so it is not "gone". Ask again.
    case stillLoading
    case gone
}
