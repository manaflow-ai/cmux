public import Foundation

/// Identifies a canonical backend screen independently of its numeric ID.
public struct ScreenID: BackendIdentifier {
    /// The UUID encoded on the wire.
    public let rawValue: UUID

    /// Creates a screen identifier.
    ///
    /// - Parameter rawValue: The stable UUID assigned to the screen.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
