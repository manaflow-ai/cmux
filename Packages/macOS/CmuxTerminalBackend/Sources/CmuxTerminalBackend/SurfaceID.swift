public import Foundation

/// Identifies a canonical backend surface independently of its numeric ID.
public struct SurfaceID: BackendIdentifier {
    /// The UUID encoded on the wire.
    public let rawValue: UUID

    /// Creates a surface identifier.
    ///
    /// - Parameter rawValue: The stable UUID assigned to the surface.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
