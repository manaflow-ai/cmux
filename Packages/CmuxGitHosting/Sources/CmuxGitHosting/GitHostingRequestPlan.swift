public import Foundation

/// A resolved, ready-to-use plan for polling one host's pull/merge requests.
///
/// A plan pairs a concrete ``GitHostingProviderSpec`` with an already-resolved token
/// for a specific host. It is the boundary the cmux sidebar poller talks to: it
/// builds `URLRequest`s (the poller runs them on its own `URLSession`, preserving its
/// caching, jitter, and timers) and parses the responses back into
/// ``HostedPullRequest`` values. Obtain one from
/// ``GitHostingResolver/resolvePlan(forHost:port:)``.
public struct GitHostingRequestPlan: Sendable {
    /// The provider definition this plan polls against.
    public let spec: GitHostingProviderSpec

    /// The host (with HTTPS port when pinned) substituted for `{host}` in templates.
    public let apiHost: String

    /// The resolved API token, or `nil` for anonymous access.
    public let token: String?

    /// Creates a request plan.
    ///
    /// - Parameters:
    ///   - spec: The provider definition.
    ///   - apiHost: The host (optionally `host:port`) for `{host}` substitution.
    ///   - token: The resolved token, or `nil` for anonymous access.
    public init(spec: GitHostingProviderSpec, apiHost: String, token: String?) {
        self.spec = spec
        self.apiHost = apiHost
        self.token = token
    }

    /// The number of requests fetched per page.
    public var pageSize: Int { spec.pageSize }

    /// The maximum number of pages to walk when scanning a repository.
    public var pageLimit: Int { spec.pageLimit }

    /// Whether the provider can filter its list down to a single source branch.
    public var supportsBranchFilter: Bool { spec.branchFilter != nil }

    /// Builds the request listing one page of a repository's pull/merge requests.
    ///
    /// - Parameters:
    ///   - reference: The repository to list.
    ///   - page: The 1-based page number, or `nil` when the provider is unpaginated.
    /// - Returns: A configured `GET` request, or `nil` if the URL could not be built.
    public func repositoryRequest(for reference: GitRemoteReference, page: Int?) -> URLRequest? {
        makeRequest(for: reference, branch: nil, extraQuery: [], page: page)
    }

    /// Builds the request listing requests opened from a specific source branch.
    ///
    /// - Parameters:
    ///   - reference: The repository to list.
    ///   - branch: The source branch to filter on.
    /// - Returns: A configured `GET` request, or `nil` if the provider has no branch
    ///   filter or the URL could not be built.
    public func branchRequest(for reference: GitRemoteReference, branch: String) -> URLRequest? {
        guard let filter = spec.branchFilter else { return nil }
        let item = GitHostingQueryItem(name: filter.name, value: filter.valueTemplate)
        return makeRequest(for: reference, branch: branch, extraQuery: [item], page: nil)
    }

    /// Parses a list response body into normalized pull requests.
    ///
    /// Use ``parsePage(from:)`` instead when walking pages: this drops items with an
    /// unmapped state, so its count cannot be compared against ``pageSize`` to detect a
    /// short final page.
    ///
    /// - Parameter data: The raw response body.
    /// - Returns: The parsed requests, or `nil` when the body is not the JSON shape
    ///   the ``GitHostingResponseSpec`` describes (a transient/error response).
    public func parsePullRequests(from data: Data) -> [HostedPullRequest]? {
        parsePage(from: data)?.pullRequests
    }

    /// Parses a list response body into one ``GitHostingPage``.
    ///
    /// Unlike ``parsePullRequests(from:)``, the page also carries the raw item count the
    /// response held before any were dropped for an unmapped state or missing fields.
    /// Pagination must terminate on ``GitHostingPage/rawItemCount`` — comparing the
    /// *mapped* count against ``pageSize`` stops early when a full page contains items a
    /// custom provider's ``GitHostingResponseSpec/stateMap`` does not cover.
    ///
    /// - Parameter data: The raw response body.
    /// - Returns: The parsed page, or `nil` when the body is not the JSON shape the
    ///   ``GitHostingResponseSpec`` describes (a transient/error response).
    public func parsePage(from data: Data) -> GitHostingPage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let array: [Any]?
        if let itemsPath = spec.response.itemsPath, !itemsPath.isEmpty {
            array = jsonValue(at: itemsPath, in: root) as? [Any]
        } else {
            array = root as? [Any]
        }
        guard let array else { return nil }

        let pullRequests = array.compactMap { element -> HostedPullRequest? in
            guard let object = element as? [String: Any] else { return nil }
            return hostedPullRequest(from: object)
        }
        return GitHostingPage(pullRequests: pullRequests, rawItemCount: array.count)
    }

    private func hostedPullRequest(from object: [String: Any]) -> HostedPullRequest? {
        let response = spec.response
        guard let number = jsonInt(at: response.number, in: object) else { return nil }
        guard let url = jsonString(at: response.url, in: object), !url.isEmpty else { return nil }

        let mergedAt = response.mergedWhenPresent.flatMap { jsonString(at: $0, in: object) }
        let state: HostedPullRequestState
        if let mergedAt, !mergedAt.isEmpty {
            state = .merged
        } else if let rawState = jsonString(at: response.state, in: object),
                  let mapped = response.stateMap[rawState.uppercased()] {
            state = mapped
        } else {
            return nil
        }

        return HostedPullRequest(
            number: number,
            state: state,
            url: url,
            updatedAt: response.updatedAt.flatMap { jsonString(at: $0, in: object) },
            mergedAt: mergedAt,
            headRefName: jsonString(at: response.headRef, in: object),
            baseRefName: response.baseRef.flatMap { jsonString(at: $0, in: object) }
        )
    }

    private var authorizationHeaderValue: String? {
        guard let token, !token.isEmpty else { return nil }
        if let scheme = spec.auth.scheme, !scheme.isEmpty {
            return "\(scheme) \(token)"
        }
        return token
    }

    private func makeRequest(
        for reference: GitRemoteReference,
        branch: String?,
        extraQuery: [GitHostingQueryItem],
        page: Int?
    ) -> URLRequest? {
        let values = templateValues(for: reference, branch: branch)

        let base = expandTemplate(spec.apiBaseURL, values)
        let normalizedBase = base.hasSuffix("/") ? base : base + "/"
        var pathPart = expandTemplate(spec.pullRequestsPath, values)
        while pathPart.hasPrefix("/") { pathPart.removeFirst() }

        guard var components = URLComponents(string: normalizedBase + pathPart) else { return nil }

        var items: [URLQueryItem] = []
        for query in spec.query {
            items.append(URLQueryItem(name: query.name, value: expandTemplate(query.value, values)))
        }
        for query in extraQuery {
            items.append(URLQueryItem(name: query.name, value: expandTemplate(query.value, values)))
        }
        if let perPageParam = spec.perPageParam {
            items.append(URLQueryItem(name: perPageParam, value: String(spec.pageSize)))
        }
        if let page, let pageParam = spec.pageParam {
            items.append(URLQueryItem(name: pageParam, value: String(page)))
        }
        components.queryItems = items.isEmpty ? nil : items

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let accept = spec.accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        request.setValue(spec.userAgent, forHTTPHeaderField: "User-Agent")
        if let authorizationHeaderValue {
            request.setValue(authorizationHeaderValue, forHTTPHeaderField: spec.auth.header)
        }
        return request
    }

    private func templateValues(for reference: GitRemoteReference, branch: String?) -> [String: String] {
        [
            "host": apiHost,
            "path": reference.path,
            "pathEncoded": percentEncodeFully(reference.path),
            "owner": reference.owner,
            "name": reference.name,
            "branch": branch ?? "",
        ]
    }
}

/// Replaces every `{key}` token in `template` with its value, leaving unknown tokens intact.
private func expandTemplate(_ template: String, _ values: [String: String]) -> String {
    var result = template
    for (key, value) in values {
        result = result.replacingOccurrences(of: "{\(key)}", with: value)
    }
    return result
}

/// Percent-encodes every character except RFC 3986 unreserved ones (so `/` becomes `%2F`).
private func percentEncodeFully(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

/// Walks a dot-separated key path through nested JSON dictionaries.
private func jsonValue(at path: String, in object: Any) -> Any? {
    var current: Any? = object
    for key in path.split(separator: ".") {
        guard let dictionary = current as? [String: Any] else { return nil }
        current = dictionary[String(key)]
        if current is NSNull { return nil }
    }
    if current is NSNull { return nil }
    return current
}

/// Reads a string leaf at `path`, coercing a numeric leaf to its string form.
private func jsonString(at path: String, in object: Any) -> String? {
    switch jsonValue(at: path, in: object) {
    case let string as String:
        return string
    case let number as NSNumber:
        return number.stringValue
    default:
        return nil
    }
}

/// Reads an integer leaf at `path`, coercing a numeric string when needed.
private func jsonInt(at path: String, in object: Any) -> Int? {
    switch jsonValue(at: path, in: object) {
    case let number as NSNumber:
        return number.intValue
    case let string as String:
        return Int(string)
    default:
        return nil
    }
}
