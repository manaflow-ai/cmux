import Foundation

/// A stable identifier for one CRDT text element.
public struct CharacterID: Codable, Comparable, Hashable, Sendable {
    /// The peer that created the element.
    public let peerID: String
    /// The peer-local monotonically increasing counter.
    public let counter: Int

    /// Creates a character identifier.
    /// - Parameters:
    ///   - peerID: The peer that created the element.
    ///   - counter: The peer-local monotonically increasing counter.
    public init(peerID: String, counter: Int) {
        self.peerID = peerID
        self.counter = counter
    }

    public static func < (lhs: CharacterID, rhs: CharacterID) -> Bool {
        if lhs.counter != rhs.counter {
            return lhs.counter < rhs.counter
        }
        return lhs.peerID < rhs.peerID
    }
}
