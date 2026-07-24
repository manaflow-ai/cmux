/// The subrouter daemon's loopback HTTP API, as consumed by cmux.
///
/// All methods take the endpoint per call so a settings change never requires
/// rebuilding the client. Implementations must be `Sendable`; the production
/// client is ``SubrouterHTTPClient``, and tests inject a fake.
///
/// Only token-free metadata crosses this seam — the daemon's admin endpoints
/// never expose credential material, and cmux never requests any.
public protocol SubrouterClienting: Sendable {
    /// `GET /_subrouter/health`: whether the daemon answers at all.
    /// - Parameter endpoint: The daemon address.
    /// - Returns: The reported `ok` flag.
    /// - Throws: ``SubrouterClientError`` when unreachable or malformed.
    func health(endpoint: SubrouterEndpoint) async throws -> Bool

    /// `GET /_subrouter/accounts`: token-free account metadata.
    /// - Parameter endpoint: The daemon address.
    /// - Returns: All configured accounts.
    /// - Throws: ``SubrouterClientError`` when unreachable or malformed.
    func accounts(endpoint: SubrouterEndpoint) async throws -> [SubrouterAccount]

    /// `GET /_subrouter/usage-status`: accounts with auth validity, the
    /// active marker, plan tier, quota windows, and credits.
    /// - Parameter endpoint: The daemon address.
    /// - Returns: All accounts with usage detail.
    /// - Throws: ``SubrouterClientError`` when unreachable or malformed.
    func usageStatuses(endpoint: SubrouterEndpoint) async throws -> [SubrouterAccountUsageStatus]

    /// `GET /_subrouter/sessions`: live agent-session → account pins.
    /// - Parameter endpoint: The daemon address.
    /// - Returns: All current session assignments.
    /// - Throws: ``SubrouterClientError`` when unreachable or malformed.
    func sessions(endpoint: SubrouterEndpoint) async throws -> [SubrouterSessionAssignment]

    /// `POST /_subrouter/reload-accounts` (loopback-only): hot-reload the
    /// daemon's on-disk account store after an external mutation.
    /// - Parameter endpoint: The daemon address.
    /// - Returns: The reload outcome.
    /// - Throws: ``SubrouterClientError`` when unreachable or malformed.
    func reloadAccounts(endpoint: SubrouterEndpoint) async throws -> SubrouterReloadResult
}
