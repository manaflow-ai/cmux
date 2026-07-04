import Foundation

/// Errors surfaced by the local inbox domain.
public enum InboxError: Error, Equatable, Sendable, CustomStringConvertible {
    /// SQLite failed to open the database.
    case openFailed(Int32)
    /// SQLite failed to prepare a statement.
    case prepareFailed(Int32, String)
    /// SQLite failed to execute or step a statement.
    case stepFailed(Int32, String)
    /// A caller supplied invalid parameters.
    case invalidParameters(String)
    /// A requested record does not exist.
    case notFound(String)
    /// The requested connector action is unsupported.
    case unsupported(String)
    /// A connector is unavailable or not configured.
    case connectorUnavailable(String)
    /// A required credential is not available in Keychain.
    case tokenUnavailable(InboxSource, String)

    /// User-safe description for CLI and socket errors.
    public var description: String {
        switch self {
        case .openFailed(let code):
            return "SQLite open failed (\(code))"
        case .prepareFailed(let code, let message):
            return "SQLite prepare failed (\(code)): \(message)"
        case .stepFailed(let code, let message):
            return "SQLite step failed (\(code)): \(message)"
        case .invalidParameters(let message):
            return message
        case .notFound(let message):
            return message
        case .unsupported(let message):
            return message
        case .connectorUnavailable(let message):
            return message
        case .tokenUnavailable(let source, let accountID):
            return "Missing \(source.rawValue) credential for \(accountID)"
        }
    }
}
