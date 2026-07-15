/// One account row from `GET /_subrouter/accounts` (token-free metadata).
///
/// The daemon deliberately exposes only safe metadata here; no credential
/// material ever crosses this API and none is stored by cmux.
public struct SubrouterAccount: Sendable, Hashable, Codable, Identifiable {
    /// The daemon's account id: the Codex account email, or the Claude
    /// profile name.
    public var id: String
    /// The provider namespace the account belongs to.
    public var provider: SubrouterProvider
    /// How the account authenticates.
    public var authMode: SubrouterAuthMode
    /// The account email when known (Claude profiles named without an `@`
    /// have no email), else `nil`.
    public var email: String?
    /// The on-disk source path of the stored auth metadata (never a secret).
    public var source: String

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case authMode = "auth_mode"
        case email
        case source
    }

    /// Creates an account row.
    /// - Parameters:
    ///   - id: The daemon's account id.
    ///   - provider: The provider namespace.
    ///   - authMode: How the account authenticates.
    ///   - email: The account email when known.
    ///   - source: The stored-auth source path.
    public init(
        id: String,
        provider: SubrouterProvider,
        authMode: SubrouterAuthMode,
        email: String? = nil,
        source: String = ""
    ) {
        self.id = id
        self.provider = provider
        self.authMode = authMode
        self.email = email
        self.source = source
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.provider = try container.decodeIfPresent(SubrouterProvider.self, forKey: .provider)
            ?? SubrouterProvider(rawValue: "")
        self.authMode = try container.decodeIfPresent(SubrouterAuthMode.self, forKey: .authMode)
            ?? SubrouterAuthMode(rawValue: "")
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
    }
}
