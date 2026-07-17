/// The summary-level loading state of a live diff screen.
public enum DiffScreenPhase: Sendable, Equatable {
    /// No summary request has started.
    case idle
    /// The initial summary request is in flight.
    case loading
    /// A summary and its changed-file list are available.
    case loaded
    /// The initial summary request failed.
    case failed(DiffScreenErrorKind)
}
