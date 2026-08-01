/// Describes the coarse lifecycle state of a pull request attached to a Fleet task.
public enum FleetPullRequestState: String, CaseIterable, Codable, Sendable {
    /// The pull request is open and still reviewable.
    case open

    /// The pull request was merged.
    case merged

    /// The pull request was closed without merging.
    case closed

    /// Indicates whether the pull request no longer needs Fleet supervision.
    public var isTerminal: Bool {
        switch self {
        case .open:
            false
        case .merged, .closed:
            true
        }
    }
}
