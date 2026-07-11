import Foundation

/// Identifies one transcript journal for a session.
public struct JournalID: Codable, Hashable, Sendable, RawRepresentable {
    /// The opaque journal identifier minted by the Mac.
    public let rawValue: String

    /// Creates a journal identifier.
    /// - Parameter rawValue: The opaque identifier value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
