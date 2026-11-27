public import Foundation

/// A request for the cmux destination profile an import entry should write to.
public enum BrowserImportDestinationRequest: Equatable, Sendable {
    /// Import into the existing cmux profile with this identifier.
    case existing(UUID)
    /// Create a new cmux profile with this display name, then import into it.
    case createNamed(String)
}
