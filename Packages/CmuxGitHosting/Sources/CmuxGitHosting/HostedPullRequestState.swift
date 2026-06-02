/// The cmux-canonical lifecycle state of a hosted pull or merge request.
///
/// Every provider's native vocabulary (GitHub `open`/`closed` + `merged_at`,
/// GitLab `opened`/`locked`/`merged`/`closed`, Bitbucket
/// `OPEN`/`MERGED`/`DECLINED`/`SUPERSEDED`, or anything a custom provider returns)
/// is mapped down to one of these three cases by a provider's state map. The raw
/// value is the uppercase token the cmux sidebar poller already understands.
public enum HostedPullRequestState: String, Sendable, Codable, Equatable, CaseIterable {
    /// The change is open and awaiting review or merge.
    case open = "OPEN"

    /// The change has been merged into its target branch.
    case merged = "MERGED"

    /// The change was closed, declined, or superseded without merging.
    case closed = "CLOSED"
}
