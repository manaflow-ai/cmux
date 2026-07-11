import Foundation

/// Carries a monotonically increasing version for one entity inside an epoch.
public struct EntityVersion: Codable, Comparable, Hashable, Sendable, RawRepresentable {
    /// The unsigned integer version value.
    public let rawValue: UInt64

    /// Creates an entity version wrapper.
    /// - Parameter rawValue: The version value for one entity.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Orders versions by their integer values.
    /// - Parameters:
    ///   - lhs: The left version.
    ///   - rhs: The right version.
    /// - Returns: Whether `lhs` is older than `rhs`.
    public static func < (lhs: EntityVersion, rhs: EntityVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
