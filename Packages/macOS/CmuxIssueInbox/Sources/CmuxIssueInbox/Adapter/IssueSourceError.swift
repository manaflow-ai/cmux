public import Foundation

/// Errors produced by issue source adapters.
public enum IssueSourceError: Error, Equatable, Sendable, LocalizedError {
    /// Required provider credentials were not available.
    case missingCredentials(provider: IssueProviderKind, envVar: String)
    /// Source configuration is missing a required field.
    case invalidConfiguration(String)
    /// The provider returned an HTTP status outside the success range.
    case httpStatus(provider: IssueProviderKind, statusCode: Int)
    /// The provider returned a structured error message.
    case providerMessage(provider: IssueProviderKind, message: String)
    /// The provider response could not be decoded.
    case decoding(provider: IssueProviderKind, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials(let provider, let envVar):
            return "\(provider.rawValue) credentials missing. Set \(envVar)."
        case .invalidConfiguration(let message):
            return message
        case .httpStatus(let provider, let statusCode):
            return "\(provider.rawValue) returned HTTP \(statusCode)."
        case .providerMessage(let provider, let message):
            return "\(provider.rawValue): \(message)"
        case .decoding(let provider, let message):
            return "\(provider.rawValue) response decode failed: \(message)"
        }
    }
}
