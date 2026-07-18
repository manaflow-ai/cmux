public import Foundation

/// Identifies one immutable lifetime of a terminal backend daemon process.
public struct DaemonInstanceID: BackendIdentifier {
    /// The UUID encoded on the wire.
    public let rawValue: UUID

    /// Creates a daemon-instance identifier.
    ///
    /// - Parameter rawValue: The UUID assigned to the daemon lifetime.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
