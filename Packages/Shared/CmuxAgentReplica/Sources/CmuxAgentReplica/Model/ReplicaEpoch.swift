import Foundation

/// Identifies one launch epoch of the Mac app.
public struct ReplicaEpoch: Codable, Hashable, Sendable, RawRepresentable {
    /// The opaque epoch value minted by the Mac app.
    public let rawValue: String

    /// Creates an epoch wrapper.
    /// - Parameter rawValue: The opaque epoch value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
