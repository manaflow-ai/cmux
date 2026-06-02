/// Describes where to find the API token for a hosting provider.
///
/// Resolution tries each environment variable in ``environment`` order first, then
/// runs ``command`` (if set) and uses its trimmed standard output. This lets cmux
/// reuse whatever credential a user already has: an env var, the `gh`/`glab` CLIs,
/// or any custom script that prints a token. The `{host}` token in ``command``
/// arguments is replaced with the concrete host, so `gh auth token --hostname {host}`
/// works for any GitHub Enterprise Server instance.
public struct GitHostingTokenSource: Sendable, Codable, Equatable {
    /// Environment variable names checked, in order, before falling back to ``command``.
    public var environment: [String]

    /// A command whose standard output is the token, or `nil` to rely on env vars only.
    ///
    /// The first element is the executable; remaining elements are arguments. Any
    /// `{host}` token in an argument is replaced with the target host.
    public var command: [String]?

    /// Creates a token source.
    ///
    /// - Parameters:
    ///   - environment: Env var names to check in order. Defaults to none.
    ///   - command: A token-printing command, or `nil`. Defaults to `nil`.
    public init(environment: [String] = [], command: [String]? = nil) {
        self.environment = environment
        self.command = command
    }

    /// A token source that resolves nothing (used for anonymous access).
    public static let none = GitHostingTokenSource()

    private enum CodingKeys: String, CodingKey {
        case environment, command
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environment = try container.decodeIfPresent([String].self, forKey: .environment) ?? []
        command = try container.decodeIfPresent([String].self, forKey: .command)
    }
}
