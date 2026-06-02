/// The user's git hosting configuration, decoded from the `gitHosting` section of
/// `~/.config/cmux/cmux.json`.
///
/// Resolution order for a given host is: a matching ``rules`` entry first, then the
/// built-in auto-detected presets (when ``autoDetect`` is on), then GitHub Enterprise
/// Server discovery via the `gh` CLI (when ``autoDiscoverGitHubEnterprise`` is on).
/// An empty config (the default) preserves cmux's original behavior: github.com is
/// auto-detected and any host `gh` is authenticated to is discovered as GHES.
///
/// ```jsonc
/// "gitHosting": {
///   "providers": [
///     { "host": "gitlab.example.com", "preset": "gitlab",
///       "token": { "environment": ["MY_GITLAB_TOKEN"] } }
///   ]
/// }
/// ```
public struct GitHostingConfig: Sendable, Codable, Equatable {
    /// User-defined host → provider rules, consulted in order (first match wins).
    public var rules: [GitHostingProviderRule]

    /// Whether to auto-detect the public hosts github.com, gitlab.com, and bitbucket.org.
    public var autoDetect: Bool

    /// Whether to discover GitHub Enterprise Server hosts by asking `gh` for a token.
    ///
    /// When on, an otherwise-unmatched host that `gh auth token --hostname <host>`
    /// can authenticate is treated as a GitHub Enterprise Server (`/api/v3/`). This
    /// is self-configuring: no hostname allowlist to maintain.
    public var autoDiscoverGitHubEnterprise: Bool

    /// Creates a git hosting configuration.
    public init(
        rules: [GitHostingProviderRule] = [],
        autoDetect: Bool = true,
        autoDiscoverGitHubEnterprise: Bool = true
    ) {
        self.rules = rules
        self.autoDetect = autoDetect
        self.autoDiscoverGitHubEnterprise = autoDiscoverGitHubEnterprise
    }

    /// The default configuration, equivalent to no `gitHosting` section at all.
    public static let `default` = GitHostingConfig()

    /// The first user rule that applies to `host`, or `nil`.
    ///
    /// - Parameter host: A lowercased host with no port.
    public func rule(matchingHost host: String) -> GitHostingProviderRule? {
        rules.first { $0.matches(host: host) }
    }

    private enum CodingKeys: String, CodingKey {
        case providers, autoDetect, autoDiscoverGitHubEnterprise
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decodeIfPresent([GitHostingProviderRule].self, forKey: .providers) ?? []
        autoDetect = try container.decodeIfPresent(Bool.self, forKey: .autoDetect) ?? true
        autoDiscoverGitHubEnterprise = try container.decodeIfPresent(
            Bool.self,
            forKey: .autoDiscoverGitHubEnterprise
        ) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !rules.isEmpty {
            try container.encode(rules, forKey: .providers)
        }
        if !autoDetect {
            try container.encode(autoDetect, forKey: .autoDetect)
        }
        if !autoDiscoverGitHubEnterprise {
            try container.encode(autoDiscoverGitHubEnterprise, forKey: .autoDiscoverGitHubEnterprise)
        }
    }
}
