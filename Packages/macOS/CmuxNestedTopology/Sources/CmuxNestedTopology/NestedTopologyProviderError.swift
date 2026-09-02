public import Foundation

/// Errors raised by nested topology provider clients.
public enum NestedTopologyProviderError: Error, Hashable, Sendable, LocalizedError {
    /// The endpoint could not be connected within the deadline.
    case connectTimeout
    /// A request/response exchange exceeded its deadline.
    case requestTimeout
    /// The peer closed the socket unexpectedly.
    case unexpectedEOF
    /// A single newline-delimited JSON line exceeded the configured byte bound.
    case oversizedLine(maxUTF8ByteCount: Int)
    /// A snapshot payload exceeded the configured byte bound.
    case oversizedSnapshot(maxUTF8ByteCount: Int)
    /// An event payload exceeded the configured byte bound.
    case oversizedEvent(maxUTF8ByteCount: Int)
    /// Received bytes were not valid UTF-8.
    case invalidUTF8
    /// A line could not be decoded as JSON.
    case malformedJSON(String)
    /// A response `id` did not match the outstanding request.
    case responseIDMismatch(expected: String, actual: String)
    /// The provider returned a structured error object.
    case providerError(code: String, message: String)
    /// Required fields were missing from an otherwise parseable payload.
    case missingRequiredField(String)
    /// The provider protocol number is outside the tested compatibility profile.
    case unsupportedProtocol(Int)
    /// The connection was cancelled by the caller.
    case cancelled
    /// A low-level transport failure occurred.
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .connectTimeout:
            return "Nested provider connect timed out."
        case .requestTimeout:
            return "Nested provider request timed out."
        case .unexpectedEOF:
            return "Nested provider closed the connection unexpectedly."
        case .oversizedLine(let maxUTF8ByteCount):
            return "Nested provider line exceeded \(maxUTF8ByteCount) UTF-8 bytes."
        case .oversizedSnapshot(let maxUTF8ByteCount):
            return "Nested provider snapshot exceeded \(maxUTF8ByteCount) UTF-8 bytes."
        case .oversizedEvent(let maxUTF8ByteCount):
            return "Nested provider event exceeded \(maxUTF8ByteCount) UTF-8 bytes."
        case .invalidUTF8:
            return "Nested provider payload was not valid UTF-8."
        case .malformedJSON:
            return "Nested provider returned malformed JSON."
        case .responseIDMismatch:
            return "Nested provider response id mismatch."
        case .providerError:
            return "Nested provider returned an error."
        case .missingRequiredField:
            return "Nested provider payload is missing a required field."
        case .unsupportedProtocol:
            return "Unsupported nested provider protocol."
        case .cancelled:
            return "Nested provider operation cancelled."
        case .transport:
            return "Nested provider transport failure."
        }
    }
}
