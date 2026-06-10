import Foundation

/// The rolled-up CI/CD check status for a pull request's head commit, reduced
/// to the three states the sidebar renders.
///
/// Raw values are stable strings (`"neutral"`, `"success"`, `"failure"`) so
/// app-side status enums can bridge via `rawValue` without a mapping table.
///
/// The probe only ever fetches a rollup for **open** pull requests (the
/// GraphQL query filters `states: OPEN`), and any state it can't positively
/// classify as success or failure collapses to ``neutral`` — so a missing
/// token, a repo with no checks configured, or an in-progress run all render
/// as the neutral dash rather than a false check or X.
public enum WorkspaceCIStatus: String, Sendable, Equatable {
    /// No checks yet, queued/in-progress, expected-but-not-reported, no token,
    /// or not yet fetched. Rendered as a dim dash.
    case neutral
    /// Every required check passed (or only neutral/skipped checks ran).
    case success
    /// At least one required check failed, errored, was cancelled, or timed out.
    case failure

    /// Maps GitHub's `statusCheckRollup.state` enum (`SUCCESS`, `FAILURE`,
    /// `ERROR`, `PENDING`, `EXPECTED`, any case) to a rendered status.
    ///
    /// `SUCCESS` → ``success``; `FAILURE`/`ERROR` → ``failure``; everything
    /// else (including `PENDING`/`EXPECTED` and unknown values) → ``neutral``.
    public init(rollupState rawState: String?) {
        switch rawState?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "SUCCESS":
            self = .success
        case "FAILURE", "ERROR":
            self = .failure
        default:
            self = .neutral
        }
    }
}
