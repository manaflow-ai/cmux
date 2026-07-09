import Foundation

/// Describes an inclusive range of journal entry sequences.
public struct EntryRange: Codable, Hashable, Sendable {
    /// The inclusive lower bound.
    public let lowerBound: EntrySeq
    /// The inclusive upper bound.
    public let upperBound: EntrySeq

    /// Creates an inclusive entry range.
    /// - Parameters:
    ///   - lowerBound: The inclusive lower bound.
    ///   - upperBound: The inclusive upper bound.
    public init(lowerBound: EntrySeq, upperBound: EntrySeq) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// Returns whether the range contains a sequence.
    /// - Parameter seq: The sequence to test.
    /// - Returns: Whether `seq` is inside the range.
    public func contains(_ seq: EntrySeq) -> Bool {
        lowerBound.rawValue <= seq.rawValue && seq.rawValue <= upperBound.rawValue
    }
}
