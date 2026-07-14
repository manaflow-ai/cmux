internal import Foundation

/// Failure decoding a `simctl list --json` payload into a device catalog.
public struct SimulatorCatalogError: Error, Sendable, CustomStringConvertible {
    /// A short description of what was malformed.
    public let message: String

    /// Creates a catalog error.
    ///
    /// - Parameter message: A short description of what was malformed.
    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}
