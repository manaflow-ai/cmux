public import Foundation

/// Identifies a canonical backend pane independently of its numeric ID.
public struct PaneID: BackendIdentifier {
    /// The UUID encoded on the wire.
    public let rawValue: UUID

    /// Creates a pane identifier.
    ///
    /// - Parameter rawValue: The stable UUID assigned to the pane.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
