/// Codex credit balance attached to `GET /_subrouter/usage-status` rows.
///
/// **Wire format warning.** Like ``SubrouterUsageWindow``, the daemon's Go
/// struct has no JSON tags, so the keys are PascalCase (`HasCredits`,
/// `Unlimited`, `Balance`). The explicit `CodingKeys` are load-bearing.
public struct SubrouterCredits: Sendable, Hashable, Codable {
    /// Whether the account has a credit balance at all.
    public var hasCredits: Bool
    /// Whether the account has unlimited credits.
    public var unlimited: Bool
    /// The formatted balance string as reported upstream (may be empty).
    public var balance: String

    private enum CodingKeys: String, CodingKey {
        case hasCredits = "HasCredits"
        case unlimited = "Unlimited"
        case balance = "Balance"
    }

    /// Creates a credits value.
    /// - Parameters:
    ///   - hasCredits: Whether the account has a credit balance.
    ///   - unlimited: Whether credits are unlimited.
    ///   - balance: The formatted balance string.
    public init(hasCredits: Bool, unlimited: Bool, balance: String) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hasCredits = try container.decodeIfPresent(Bool.self, forKey: .hasCredits) ?? false
        self.unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
        self.balance = try container.decodeIfPresent(String.self, forKey: .balance) ?? ""
    }
}
