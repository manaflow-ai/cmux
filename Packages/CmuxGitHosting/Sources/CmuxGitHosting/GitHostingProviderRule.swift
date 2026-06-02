/// One user-configured mapping from a git host to a provider definition.
///
/// A rule is how a user teaches cmux about a host it cannot auto-detect: a
/// self-hosted GitLab, a Bitbucket Server, a GitHub Enterprise Server on a custom
/// API path, or a completely bespoke service. The two common shapes are:
///
/// ```jsonc
/// // Reuse a built-in preset, override only what differs:
/// { "host": "gitlab.example.com", "preset": "gitlab",
///   "token": { "environment": ["MY_GITLAB_TOKEN"] } }
///
/// // Describe an unknown host from scratch:
/// { "host": "git.internal", "spec": { /* full GitHostingProviderSpec */ } }
/// ```
///
/// ``host`` matches either an exact host or a `*.suffix` wildcard
/// (`*.example.com` matches `example.com` and any subdomain).
public struct GitHostingProviderRule: Sendable, Codable, Equatable {
    /// The host this rule applies to: an exact host or a `*.suffix` wildcard.
    public var host: String

    /// A built-in preset to base the provider on (`github`, `gitlab`, `bitbucket`), or `nil`.
    public var preset: String?

    /// Overrides the preset's REST API base URL (e.g. for a self-hosted instance).
    public var apiBaseURL: String?

    /// Overrides the preset's token source.
    public var token: GitHostingTokenSource?

    /// A complete, from-scratch provider spec; takes precedence over ``preset``.
    public var spec: GitHostingProviderSpec?

    /// Creates a provider rule.
    public init(
        host: String,
        preset: String? = nil,
        apiBaseURL: String? = nil,
        token: GitHostingTokenSource? = nil,
        spec: GitHostingProviderSpec? = nil
    ) {
        self.host = host
        self.preset = preset
        self.apiBaseURL = apiBaseURL
        self.token = token
        self.spec = spec
    }

    /// Whether this rule applies to `candidateHost`.
    ///
    /// - Parameter candidateHost: A lowercased host with no port.
    public func matches(host candidateHost: String) -> Bool {
        let pattern = host.lowercased()
        let candidate = candidateHost.lowercased()
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            guard !suffix.isEmpty else { return false }
            return candidate == suffix || candidate.hasSuffix("." + suffix)
        }
        return candidate == pattern
    }

    /// Resolves this rule into a concrete spec, applying overrides, or `nil` if invalid.
    ///
    /// A full ``spec`` is used as-is (with ``apiBaseURL``/``token`` overrides applied);
    /// otherwise a named ``preset`` is loaded and overridden. A rule that names neither
    /// resolves to `nil` and is skipped.
    public func resolvedSpec() -> GitHostingProviderSpec? {
        var resolved: GitHostingProviderSpec?
        if let spec {
            resolved = spec
        } else if let preset, let preset = GitHostingPreset.named(preset) {
            resolved = preset.spec
        }
        guard var resolved else { return nil }
        if let apiBaseURL { resolved.apiBaseURL = apiBaseURL }
        if let token { resolved.auth.token = token }
        return resolved
    }
}
