/// Fixed vocabulary for Feed work; durations do not imply pixel presentation.
public enum MobileFeedUpdateStage: String, CaseIterable, Sendable {
    /// Successful feed.list request, including transport and host work.
    case fetch
    /// Snapshot decode plus worker scheduling and return to the shell actor.
    case decode
    /// Synchronous snapshot application and merged model projection.
    case apply
    /// Row preparation through publication, excluding deliberate search debounce.
    case projection
}
