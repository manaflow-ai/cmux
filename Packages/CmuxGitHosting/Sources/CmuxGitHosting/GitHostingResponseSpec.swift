/// Maps a provider's JSON list response onto ``HostedPullRequest`` fields.
///
/// Every field path is a dot-separated key path into one pull request object (e.g.
/// `head.ref`, `links.html.href`, `source.branch.name`). This is the heart of the
/// "describe any host" capability: a custom provider only has to name where each
/// value lives in its JSON.
public struct GitHostingResponseSpec: Sendable, Codable, Equatable {
    /// Dotted path to the array of pull requests, or `nil`/empty when the response
    /// body is itself the array. GitHub and GitLab return a top-level array (`nil`);
    /// Bitbucket wraps them under `values`.
    public var itemsPath: String?

    /// Path to the user-facing request number (`number`, `iid`, `id`).
    public var number: String

    /// Path to the web URL (`html_url`, `web_url`, `links.html.href`).
    public var url: String

    /// Path to the native state string (`state`).
    public var state: String

    /// Path to a separate merge timestamp whose mere presence means "merged".
    ///
    /// GitHub reports `state: "closed"` for merged PRs and distinguishes them only by
    /// a non-null `merged_at`; setting this to `merged_at` makes such PRs map to
    /// ``HostedPullRequestState/merged``. Providers that report a `merged` state
    /// directly (GitLab, Bitbucket) leave this `nil`.
    public var mergedWhenPresent: String?

    /// Path to the last-updated timestamp (`updated_at`, `updated_on`).
    public var updatedAt: String?

    /// Path to the source / head branch name (`head.ref`, `source_branch`, `source.branch.name`).
    public var headRef: String

    /// Path to the target / base branch name (`base.ref`, `target_branch`, `destination.branch.name`).
    public var baseRef: String?

    /// Maps an uppercased native state token to a cmux-canonical state.
    ///
    /// Lookups uppercase the provider's value first, so `opened`/`OPENED` both match
    /// an `OPENED` key. Any state absent from the map drops the request from the
    /// sidebar (cmux only renders open/merged/closed).
    public var stateMap: [String: HostedPullRequestState]

    /// Creates a response spec.
    public init(
        itemsPath: String? = nil,
        number: String,
        url: String,
        state: String,
        mergedWhenPresent: String? = nil,
        updatedAt: String? = nil,
        headRef: String,
        baseRef: String? = nil,
        stateMap: [String: HostedPullRequestState]
    ) {
        self.itemsPath = itemsPath
        self.number = number
        self.url = url
        self.state = state
        self.mergedWhenPresent = mergedWhenPresent
        self.updatedAt = updatedAt
        self.headRef = headRef
        self.baseRef = baseRef
        self.stateMap = stateMap
    }
}
