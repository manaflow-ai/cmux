/// Describes how a provider's REST requests are authenticated.
public struct GitHostingAuthSpec: Sendable, Codable, Equatable {
    /// The HTTP header carrying the credential (almost always `Authorization`).
    public var header: String

    /// The scheme prefix prepended to the token, e.g. `Bearer` → `Authorization: Bearer <token>`.
    ///
    /// `nil` sends the raw token as the header value with no prefix.
    public var scheme: String?

    /// Where the token comes from. See ``GitHostingTokenSource``.
    public var token: GitHostingTokenSource

    /// Whether the provider may be polled with no token at all.
    ///
    /// `true` for github.com (public repositories are readable anonymously), `false`
    /// for hosts whose API rejects unauthenticated requests. When `false` and no
    /// token resolves, cmux skips the host entirely instead of issuing a doomed call.
    public var allowsAnonymous: Bool

    /// Creates an auth spec.
    ///
    /// - Parameters:
    ///   - header: The credential header. Defaults to `Authorization`.
    ///   - scheme: The scheme prefix. Defaults to `Bearer`.
    ///   - token: The token source.
    ///   - allowsAnonymous: Whether anonymous polling is allowed. Defaults to `false`.
    public init(
        header: String = "Authorization",
        scheme: String? = "Bearer",
        token: GitHostingTokenSource,
        allowsAnonymous: Bool = false
    ) {
        self.header = header
        self.scheme = scheme
        self.token = token
        self.allowsAnonymous = allowsAnonymous
    }

    private enum CodingKeys: String, CodingKey {
        case header, scheme, token, allowsAnonymous
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decodeIfPresent(String.self, forKey: .header) ?? "Authorization"
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme) ?? "Bearer"
        token = try container.decodeIfPresent(GitHostingTokenSource.self, forKey: .token) ?? .none
        allowsAnonymous = try container.decodeIfPresent(Bool.self, forKey: .allowsAnonymous) ?? false
    }
}
