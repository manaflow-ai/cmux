/// Rejects decoded frames that would move a displayed subscription backward.
struct BrowserStreamFrameSequencePolicy: Equatable, Sendable {
    /// The newest accepted sequence, or `nil` before a frame is accepted.
    private(set) var newestDecodedSequence: UInt64?

    /// Creates an empty sequence policy.
    init() {
        newestDecodedSequence = nil
    }

    /// Accepts a decoded sequence only when it is newer than the accepted high-water mark.
    /// - Parameter sequence: The decoded frame sequence.
    /// - Returns: Whether the frame may be displayed.
    mutating func accept(_ sequence: UInt64) -> Bool {
        if let newestDecodedSequence, sequence <= newestDecodedSequence {
            return false
        }
        newestDecodedSequence = sequence
        return true
    }

    /// Clears the high-water mark for a new stream subscription.
    mutating func reset() {
        newestDecodedSequence = nil
    }
}
