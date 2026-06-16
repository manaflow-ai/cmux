public import Foundation

/// The cadence-relevant classification of a PR refresh result. Persisted per probe key so the focus-change reschedule
/// hook can recompute deadlines without rerunning the full classifier.
public enum WorkspacePullRequestPollOutcome: Sendable, Equatable {
    case openPullRequest
    case terminalPullRequest
    case noPullRequest
    case unsupportedRepository
    case transientFailure(hadTerminalState: Bool)
}
