/// The result of `POST /_subrouter/reload-accounts` (loopback-only): the
/// daemon hot-reloaded its on-disk account store.
public struct SubrouterReloadResult: Sendable, Hashable, Codable {
    /// Whether the reload succeeded.
    public var ok: Bool
    /// How many accounts the daemon loaded.
    public var accounts: Int
    /// How many accounts got a fresh usage score during the reload.
    public var usageRefreshed: Int

    private enum CodingKeys: String, CodingKey {
        case ok
        case accounts
        case usageRefreshed = "usage_refreshed"
    }

    /// Creates a reload result.
    /// - Parameters:
    ///   - ok: Whether the reload succeeded.
    ///   - accounts: How many accounts were loaded.
    ///   - usageRefreshed: How many accounts got fresh usage scores.
    public init(ok: Bool, accounts: Int, usageRefreshed: Int) {
        self.ok = ok
        self.accounts = accounts
        self.usageRefreshed = usageRefreshed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        self.accounts = try container.decodeIfPresent(Int.self, forKey: .accounts) ?? 0
        self.usageRefreshed = try container.decodeIfPresent(Int.self, forKey: .usageRefreshed) ?? 0
    }
}
