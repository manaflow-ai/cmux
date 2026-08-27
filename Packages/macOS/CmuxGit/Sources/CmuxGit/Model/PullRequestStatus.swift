import Foundation

/// The lifecycle state of a GitHub pull request, as the probe reports it.
///
/// Raw values are stable strings (`"open"`, `"merged"`, `"closed"`) so app-side
/// status enums can bridge via `rawValue` without a mapping table.
public enum PullRequestStatus: String, Sendable {
    /// The pull request is open.
    case open
    /// The pull request was merged.
    case merged
    /// The pull request was closed without merging.
    case closed

    /// Parses GitHub's `state` string (`"OPEN"`, `"MERGED"`, `"CLOSED"`, any
    /// case, surrounding whitespace tolerated). Returns `nil` for anything else.
    public init?(githubState rawState: String) {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "OPEN":
            self = .open
        case "MERGED":
            self = .merged
        case "CLOSED":
            self = .closed
        default:
            return nil
        }
    }
}
