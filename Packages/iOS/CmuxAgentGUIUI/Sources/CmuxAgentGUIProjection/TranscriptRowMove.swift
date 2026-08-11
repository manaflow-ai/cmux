/// Index movement for a stable row identity.
public struct TranscriptRowMove: Hashable, Sendable {
    /// The index in the previous projection.
    public let from: Int
    /// The index in the new projection.
    public let to: Int

    /// Creates row movement metadata.
    /// - Parameters:
    ///   - from: The index in the previous projection.
    ///   - to: The index in the new projection.
    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}
