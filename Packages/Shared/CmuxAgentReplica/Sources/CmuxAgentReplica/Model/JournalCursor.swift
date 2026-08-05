import Foundation

/// An opaque server-issued position in a journal.
///
/// Clients persist and return cursors verbatim. The encoded value is not a
/// sequence number and its representation may change between server versions.
public struct JournalCursor: Codable, Hashable, Sendable, RawRepresentable {
    /// The opaque wire value.
    public let rawValue: String

    /// Creates an opaque journal cursor.
    /// - Parameter rawValue: The server-issued wire value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
