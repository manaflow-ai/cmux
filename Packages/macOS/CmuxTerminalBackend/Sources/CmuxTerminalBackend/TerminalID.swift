public import Foundation

/// Identifies one terminal entity in backend protocol extensions.
public struct TerminalID: BackendIdentifier {
    /// The UUID encoded on the wire.
    public let rawValue: UUID

    /// Creates a terminal identifier.
    ///
    /// - Parameter rawValue: The stable UUID assigned to the terminal.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
