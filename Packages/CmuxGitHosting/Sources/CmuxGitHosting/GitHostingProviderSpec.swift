/// A complete, declarative description of how to list a repository's pull/merge
/// requests over a host's REST API.
///
/// A spec is the single source of truth a ``GitHostingRequestPlan`` needs to build
/// requests and parse responses, so it doubles as cmux's built-in provider
/// definitions (see ``GitHostingPreset``) **and** the fully customizable escape
/// hatch a user can write in `cmux.json` for any unsupported host.
///
/// ### Template tokens
///
/// ``apiBaseURL``, ``pullRequestsPath``, ``GitHostingQueryItem/value``, and a
/// ``GitHostingBranchFilter`` value template may contain these tokens, replaced when
/// a request is built for a concrete ``GitRemoteReference``:
///
/// - `{host}` — the host (with HTTPS port if one was pinned), e.g. `ghe.example.com`
/// - `{path}` — the full repo path, e.g. `group/subgroup/app`
/// - `{pathEncoded}` — `{path}` percent-encoded including slashes (`group%2Fsubgroup%2Fapp`)
/// - `{owner}` — the first path segment
/// - `{name}` — the last path segment
/// - `{branch}` — the workspace branch (branch filter only)
public struct GitHostingProviderSpec: Sendable, Codable, Equatable {
    /// The REST API base URL; must end with `/`. May template `{host}`.
    public var apiBaseURL: String

    /// The pull/merge request collection path appended to ``apiBaseURL``.
    public var pullRequestsPath: String

    /// Static query items always sent with the list request.
    public var query: [GitHostingQueryItem]

    /// The page-number query parameter name, or `nil` for unpaginated APIs.
    public var pageParam: String?

    /// The per-page-size query parameter name (`per_page`, `pagelen`), or `nil`.
    public var perPageParam: String?

    /// The page size requested per call.
    public var pageSize: Int

    /// The maximum number of pages to walk when scanning a repository's requests.
    public var pageLimit: Int

    /// How to filter the list down to one source branch, or `nil` if unsupported.
    public var branchFilter: GitHostingBranchFilter?

    /// The `Accept` header value, or `nil` to send none.
    public var accept: String?

    /// The `User-Agent` header value sent with every request.
    public var userAgent: String

    /// How requests are authenticated. See ``GitHostingAuthSpec``.
    public var auth: GitHostingAuthSpec

    /// How list responses are mapped onto ``HostedPullRequest``. See ``GitHostingResponseSpec``.
    public var response: GitHostingResponseSpec

    /// Creates a provider spec.
    public init(
        apiBaseURL: String,
        pullRequestsPath: String,
        query: [GitHostingQueryItem] = [],
        pageParam: String? = "page",
        perPageParam: String? = "per_page",
        pageSize: Int = 100,
        pageLimit: Int = 2,
        branchFilter: GitHostingBranchFilter? = nil,
        accept: String? = nil,
        userAgent: String = "cmux-workspace-pr-poller",
        auth: GitHostingAuthSpec,
        response: GitHostingResponseSpec
    ) {
        self.apiBaseURL = apiBaseURL
        self.pullRequestsPath = pullRequestsPath
        self.query = query
        self.pageParam = pageParam
        self.perPageParam = perPageParam
        self.pageSize = pageSize
        self.pageLimit = pageLimit
        self.branchFilter = branchFilter
        self.accept = accept
        self.userAgent = userAgent
        self.auth = auth
        self.response = response
    }

    private enum CodingKeys: String, CodingKey {
        case apiBaseURL, pullRequestsPath, query, pageParam, perPageParam
        case pageSize, pageLimit, branchFilter, accept, userAgent, auth, response
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiBaseURL = try container.decode(String.self, forKey: .apiBaseURL)
        pullRequestsPath = try container.decode(String.self, forKey: .pullRequestsPath)
        query = try container.decodeIfPresent([GitHostingQueryItem].self, forKey: .query) ?? []
        pageParam = try container.decodeIfPresent(String.self, forKey: .pageParam) ?? "page"
        perPageParam = try container.decodeIfPresent(String.self, forKey: .perPageParam) ?? "per_page"
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? 100
        pageLimit = try container.decodeIfPresent(Int.self, forKey: .pageLimit) ?? 2
        branchFilter = try container.decodeIfPresent(GitHostingBranchFilter.self, forKey: .branchFilter)
        accept = try container.decodeIfPresent(String.self, forKey: .accept)
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent) ?? "cmux-workspace-pr-poller"
        auth = try container.decode(GitHostingAuthSpec.self, forKey: .auth)
        response = try container.decode(GitHostingResponseSpec.self, forKey: .response)
    }
}
