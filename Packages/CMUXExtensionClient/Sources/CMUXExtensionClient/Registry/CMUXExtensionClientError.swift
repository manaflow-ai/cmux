import Foundation

/// Errors raised by the sidebar extension host client.
public enum CMUXExtensionClientError: Error, Equatable, Sendable {
    /// More than one extension used the same manifest identifier.
    case duplicateExtensionIdentifier(String)
    /// No registered extension matched the requested identifier.
    case extensionNotFound(String)
}
