/// Codex credit balance attached to `GET /_subrouter/usage-status` rows.
///
/// **Wire format warning.** Like ``SubrouterUsageWindow``, released daemons
/// have emitted PascalCase (`HasCredits`, `Unlimited`, `Balance`) and
/// snake_case (`has_credits`, `unlimited`, `balance`) keys. The explicit
/// decoder accepts both dialects.
public struct SubrouterCredits: Sendable, Hashable, Codable {
    /// Whether the account has a credit balance at all.
    public var hasCredits: Bool
    /// Whether the account has unlimited credits.
    public var unlimited: Bool
    /// The formatted balance string as reported upstream (may be empty).
    public var balance: String

    private enum CodingKeys: String, CodingKey {
        case hasCredits = "HasCredits"
        case snakeHasCredits = "has_credits"
        case unlimited = "Unlimited"
        case snakeUnlimited = "unlimited"
        case balance = "Balance"
        case snakeBalance = "balance"
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
        self.hasCredits = try container.decodeIfPresent(Bool.self, forKey: .hasCredits)
            ?? container.decodeIfPresent(Bool.self, forKey: .snakeHasCredits)
            ?? false
        self.unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited)
            ?? container.decodeIfPresent(Bool.self, forKey: .snakeUnlimited)
            ?? false
        self.balance = try container.decodeIfPresent(String.self, forKey: .balance)
            ?? container.decodeIfPresent(String.self, forKey: .snakeBalance)
            ?? ""
    }

    /// Encodes the canonical PascalCase daemon shape; decoding accepts the
    /// snake_case hosted-worker dialect as well.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hasCredits, forKey: .hasCredits)
        try container.encode(unlimited, forKey: .unlimited)
        try container.encode(balance, forKey: .balance)
    }
}
