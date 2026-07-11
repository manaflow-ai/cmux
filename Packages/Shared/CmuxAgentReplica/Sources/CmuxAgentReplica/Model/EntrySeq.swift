import Foundation

/// Identifies an entry's sequence number within a journal.
public struct EntrySeq: Codable, Comparable, Hashable, Sendable, RawRepresentable {
    /// The integer sequence value.
    public let rawValue: Int

    /// Creates an entry sequence wrapper.
    /// - Parameter rawValue: The journal-local sequence number.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Orders entry sequences by their integer values.
    /// - Parameters:
    ///   - lhs: The left sequence.
    ///   - rhs: The right sequence.
    /// - Returns: Whether `lhs` precedes `rhs`.
    public static func < (lhs: EntrySeq, rhs: EntrySeq) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
