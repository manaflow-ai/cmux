struct TextRange: Sendable, Equatable {
    let lowerBound: Int
    let upperBound: Int

    var isEmpty: Bool { lowerBound >= upperBound }
}
