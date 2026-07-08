/// Columns used by the Fleet board projection.
public enum FleetBoardColumn: String, CaseIterable, Codable, Sendable {
    /// Tasks waiting for scheduler dispatch.
    case queue

    /// Tasks currently being provisioned, launched, supervised, or retried.
    case running

    /// Tasks waiting for human input.
    case needsInput

    /// Tasks waiting for pull request review.
    case review

    /// Tasks that have reached a terminal state.
    case done
}
