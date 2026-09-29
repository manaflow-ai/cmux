import Foundation

/// A parsed search query. Whitespace separates tokens; every token must match.
nonisolated public struct FuzzyQuery: Sendable, Equatable {
    public let raw: String
    let tokens: [ContiguousArray<UInt32>]
    let tokenMasks: [UInt64]
    /// Union of all token masks.
    let mask: UInt64
    /// All tokens joined without spaces, for acronym checks.
    let joined: ContiguousArray<UInt32>
    /// The folded query with single spaces, for exact and prefix checks.
    let phrase: ContiguousArray<UInt32>
    /// Tokens laid end to end, with `ranges` marking each token, so a scan
    /// can take one buffer pointer for the whole query.
    let flat: ContiguousArray<UInt32>
    let ranges: [Range<Int>]

    public init(_ string: String) {
        raw = string
        let words = string.split(whereSeparator: { $0.isWhitespace })
        tokens = words.map { ContiguousArray($0.unicodeScalars.map(FuzzyText.fold)) }
        tokenMasks = tokens.map { FuzzyMask.mask($0) }
        mask = tokenMasks.reduce(0, |)
        joined = ContiguousArray(tokens.joined())
        phrase = ContiguousArray(words.joined(separator: " ").unicodeScalars.map(FuzzyText.fold))
        flat = joined
        var ranges: [Range<Int>] = []
        var offset = 0
        for token in tokens {
            ranges.append(offset..<(offset + token.count))
            offset += token.count
        }
        self.ranges = ranges
    }

    public var isEmpty: Bool { tokens.isEmpty }

    /// Union of the token character masks (see `FuzzyText.characterMask`).
    public var characterMask: UInt64 { mask }

    /// Whether every match of `self` is also a match of `previous`, so an
    /// incremental search can filter the previous result instead of the
    /// whole candidate set.
    public func refines(_ previous: FuzzyQuery) -> Bool {
        guard !previous.isEmpty, tokens.count >= previous.tokens.count else { return false }
        for (index, token) in previous.tokens.enumerated() {
            let current = tokens[index]
            if index == previous.tokens.count - 1 {
                // The last token may have grown.
                guard current.starts(with: token) else { return false }
            } else if current != token {
                return false
            }
        }
        return true
    }
}

/// One searchable field of a candidate with its weight in percent.
nonisolated public struct FuzzyField: Sendable {
    public let text: FuzzyText
    public let weight: Int32

    public init(_ text: FuzzyText, weight: Int32 = 100) {
        self.text = text
        self.weight = weight
    }
}
