/// The built-in provider definitions cmux ships, covering the mainstream hosts.
///
/// A preset is just a named ``GitHostingProviderSpec``. The resolver auto-selects one
/// by host (see ``builtIn(forHost:)``), and a `cmux.json` rule can name one (see
/// ``named(_:)``) to reuse the wiring for a self-hosted instance while overriding
/// only the base URL and token source. GitHub Enterprise Server reuses ``github``
/// with a per-host `/api/v3/` base URL.
public enum GitHostingPreset: String, Sendable, CaseIterable {
    /// github.com and GitHub Enterprise Server (REST `/pulls`).
    case github

    /// gitlab.com and self-hosted GitLab (REST `/api/v4` merge requests).
    case gitlab

    /// Bitbucket Cloud (REST `/2.0` pull requests).
    case bitbucketCloud

    /// The declarative spec backing this preset.
    public var spec: GitHostingProviderSpec {
        switch self {
        case .github:
            return GitHostingProviderSpec(
                apiBaseURL: "https://api.github.com/",
                pullRequestsPath: "repos/{path}/pulls",
                query: [
                    GitHostingQueryItem(name: "state", value: "all"),
                    GitHostingQueryItem(name: "sort", value: "updated"),
                    GitHostingQueryItem(name: "direction", value: "desc"),
                ],
                branchFilter: GitHostingBranchFilter(name: "head", valueTemplate: "{owner}:{branch}"),
                accept: "application/vnd.github+json",
                auth: GitHostingAuthSpec(
                    token: GitHostingTokenSource(
                        environment: ["GH_TOKEN", "GITHUB_TOKEN"],
                        command: ["gh", "auth", "token"]
                    ),
                    allowsAnonymous: true
                ),
                response: GitHostingResponseSpec(
                    number: "number",
                    url: "html_url",
                    state: "state",
                    mergedWhenPresent: "merged_at",
                    updatedAt: "updated_at",
                    headRef: "head.ref",
                    baseRef: "base.ref",
                    stateMap: ["OPEN": .open, "CLOSED": .closed]
                )
            )

        case .gitlab:
            return GitHostingProviderSpec(
                apiBaseURL: "https://{host}/api/v4/",
                pullRequestsPath: "projects/{pathEncoded}/merge_requests",
                query: [
                    GitHostingQueryItem(name: "state", value: "all"),
                    GitHostingQueryItem(name: "order_by", value: "updated_at"),
                    GitHostingQueryItem(name: "sort", value: "desc"),
                ],
                branchFilter: GitHostingBranchFilter(name: "source_branch", valueTemplate: "{branch}"),
                accept: "application/json",
                auth: GitHostingAuthSpec(
                    token: GitHostingTokenSource(environment: ["GITLAB_TOKEN", "GL_TOKEN"])
                ),
                response: GitHostingResponseSpec(
                    number: "iid",
                    url: "web_url",
                    state: "state",
                    updatedAt: "updated_at",
                    headRef: "source_branch",
                    baseRef: "target_branch",
                    stateMap: ["OPENED": .open, "LOCKED": .open, "MERGED": .merged, "CLOSED": .closed]
                )
            )

        case .bitbucketCloud:
            return GitHostingProviderSpec(
                apiBaseURL: "https://api.bitbucket.org/2.0/",
                pullRequestsPath: "repositories/{path}/pullrequests",
                query: [
                    GitHostingQueryItem(name: "state", value: "OPEN"),
                    GitHostingQueryItem(name: "state", value: "MERGED"),
                    GitHostingQueryItem(name: "state", value: "DECLINED"),
                    GitHostingQueryItem(name: "state", value: "SUPERSEDED"),
                    GitHostingQueryItem(name: "sort", value: "-updated_on"),
                ],
                perPageParam: "pagelen",
                pageSize: 50,
                branchFilter: GitHostingBranchFilter(
                    name: "q",
                    valueTemplate: "source.branch.name=\"{branch}\""
                ),
                accept: "application/json",
                auth: GitHostingAuthSpec(
                    token: GitHostingTokenSource(environment: ["BITBUCKET_TOKEN"])
                ),
                response: GitHostingResponseSpec(
                    itemsPath: "values",
                    number: "id",
                    url: "links.html.href",
                    state: "state",
                    updatedAt: "updated_on",
                    headRef: "source.branch.name",
                    baseRef: "destination.branch.name",
                    stateMap: ["OPEN": .open, "MERGED": .merged, "DECLINED": .closed, "SUPERSEDED": .closed]
                )
            )
        }
    }

    /// Returns the preset auto-detected for a well-known public host, or `nil`.
    ///
    /// - Parameter host: A lowercased host with no port.
    public static func builtIn(forHost host: String) -> GitHostingPreset? {
        switch host {
        case "github.com", "www.github.com":
            return .github
        case "gitlab.com", "www.gitlab.com":
            return .gitlab
        case "bitbucket.org", "www.bitbucket.org":
            return .bitbucketCloud
        default:
            return nil
        }
    }

    /// Returns the preset a `cmux.json` rule names, accepting common aliases.
    ///
    /// - Parameter name: A preset identifier (`github`, `gitlab`, `bitbucket`, …).
    public static func named(_ name: String) -> GitHostingPreset? {
        switch name.lowercased() {
        case "github", "github-enterprise", "ghes":
            return .github
        case "gitlab":
            return .gitlab
        case "bitbucket", "bitbucket-cloud", "bitbucketcloud":
            return .bitbucketCloud
        default:
            return nil
        }
    }
}
