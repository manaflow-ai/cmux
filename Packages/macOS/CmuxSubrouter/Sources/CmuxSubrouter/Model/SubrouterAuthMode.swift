/// How a subrouter account authenticates against its provider.
///
/// Raw-value struct rather than an `enum` so unknown future modes decode
/// losslessly. The daemon currently reports ``oauth`` and ``apiKey``.
public struct SubrouterAuthMode: RawRepresentable, Hashable, Sendable, Codable {
    /// OAuth-token authentication (`"oauth"`).
    public static let oauth = SubrouterAuthMode(rawValue: "oauth")
    /// Static API-key authentication (`"apikey"`).
    public static let apiKey = SubrouterAuthMode(rawValue: "apikey")

    /// The wire string exactly as the daemon reported it.
    public let rawValue: String

    /// Creates an auth mode from its wire string.
    /// - Parameter rawValue: The auth-mode string (e.g. `"oauth"`).
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
