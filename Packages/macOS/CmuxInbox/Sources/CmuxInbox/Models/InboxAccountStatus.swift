import Foundation

/// Connection state for one external account or helper.
public enum InboxAccountStatus: String, Codable, CaseIterable, Sendable, Hashable {
    /// No credentials or helper have been configured.
    case disconnected
    /// Credentials exist and the connector is ready.
    case connected
    /// The connector is currently fetching or reconciling data.
    case syncing
    /// The connector can run but needs user attention.
    case degraded
    /// The connector has no token in Keychain for the account.
    case missingCredentials
    /// The iMessage helper binary is not available.
    case missingHelper
    /// The helper or source denied required local permissions.
    case permissionDenied
    /// The remote service has rate-limited the connector.
    case rateLimited
    /// The stored token is expired or revoked.
    case tokenExpired
    /// The connector failed for an unknown or source-specific reason.
    case error
}
