/// A half-open range expressed in user-perceived character offsets.
struct DiffCharacterRange: Sendable, Equatable, Hashable {
    /// The first highlighted character offset.
    let lowerBound: Int
    /// The offset immediately after the highlighted characters.
    let upperBound: Int

    /// Creates a character-offset range.
    /// - Parameters:
    ///   - lowerBound: The first included offset.
    ///   - upperBound: The first excluded offset.
    init(lowerBound: Int, upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}
