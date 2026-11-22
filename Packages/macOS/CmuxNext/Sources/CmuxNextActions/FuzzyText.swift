import Foundation

/// Text prepared once for repeated fuzzy matching: case, diacritic, and width
/// folded scalars, a per-position boundary bonus, and a character-set mask
/// for fast rejection. Build it when the candidate set changes, not per
/// keystroke.
nonisolated public struct FuzzyText: Sendable {
    public let original: String
    /// One folded scalar per scalar of `original`, so match positions map
    /// straight back for highlighting.
    let folded: ContiguousArray<UInt32>
    let bonus: ContiguousArray<Int32>
    /// Folded scalars at word starts, for acronym matches ("sr" -> "Split Right").
    let initials: ContiguousArray<UInt32>
    /// Bit set of the characters present (see `FuzzyMask`).
    let mask: UInt64

    public init(_ string: String) {
        original = string
        var folded = ContiguousArray<UInt32>()
        var bonus = ContiguousArray<Int32>()
        var initials = ContiguousArray<UInt32>()
        folded.reserveCapacity(string.unicodeScalars.count)
        bonus.reserveCapacity(string.unicodeScalars.count)
        var mask: UInt64 = 0
        var previous: CharClass = .delimiter
        var isFirst = true
        for scalar in string.unicodeScalars {
            let folding = Self.fold(scalar)
            folded.append(folding)
            mask |= FuzzyMask.bit(folding)
            let current = CharClass(scalar)
            let b = Self.boundaryBonus(previous: previous, current: current, isFirst: isFirst)
            bonus.append(b)
            if b >= FuzzyMatcher.camelBonus, current != .delimiter, current != .ideograph {
                initials.append(folding)
            }
            previous = current
            isFirst = false
        }
        self.folded = folded
        self.bonus = bonus
        self.initials = initials
        self.mask = mask
    }

    public var isEmpty: Bool { folded.isEmpty }

    /// Character-set mask; a query whose `characterMask` is not a subset of
    /// this cannot match. Callers holding many texts can union these to skip
    /// whole candidates.
    public var characterMask: UInt64 { mask }

    static func fold(_ scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        if value < 0x80 {
            // ASCII fast path.
            if value >= 0x41, value <= 0x5A { return value + 0x20 }
            return value
        }
        let folded = String(Character(scalar)).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        return folded.unicodeScalars.first?.value ?? value
    }

    static func boundaryBonus(previous: CharClass, current: CharClass, isFirst: Bool) -> Int32 {
        if current == .delimiter { return 0 }
        if current == .ideograph { return isFirst ? FuzzyMatcher.startBonus : FuzzyMatcher.ideographBonus }
        if isFirst { return FuzzyMatcher.startBonus }
        switch (previous, current) {
        case (.delimiter, _): return FuzzyMatcher.wordBonus
        case (.lower, .upper): return FuzzyMatcher.camelBonus
        case (.ideograph, _): return FuzzyMatcher.wordBonus
        case (.lower, .digit), (.upper, .digit), (.digit, .lower), (.digit, .upper): return FuzzyMatcher.digitBonus
        default: return 0
        }
    }
}

/// 64-bit character-set masks. A token can only match a text whose mask
/// contains the token's mask, which rejects most candidates with one AND.
nonisolated enum FuzzyMask {
    static func bit(_ folded: UInt32) -> UInt64 {
        switch folded {
        case 0x61...0x7A: return 1 << UInt64(folded - 0x61)  // a-z: bits 0-25
        case 0x30...0x39: return 1 << UInt64(26 + folded - 0x30)  // 0-9: bits 26-35
        case 0x20: return 0  // spaces never need to match
        default: return 1 << UInt64(36 + folded % 28)  // everything else hashed into 36-63
        }
    }

    static func mask(_ scalars: some Sequence<UInt32>) -> UInt64 {
        scalars.reduce(0) { $0 | bit($1) }
    }
}

nonisolated enum CharClass: Equatable {
    case lower, upper, digit, delimiter, ideograph, other

    init(_ scalar: Unicode.Scalar) {
        let v = scalar.value
        switch v {
        case 0x61...0x7A: self = .lower
        case 0x41...0x5A: self = .upper
        case 0x30...0x39: self = .digit
        case 0x20, 0x09, 0x2D, 0x5F, 0x2E, 0x2F, 0x3A, 0x2C, 0x28, 0x29, 0x5B, 0x5D, 0x3C, 0x3E, 0x2026, 0x3001, 0x3002, 0xFF08, 0xFF09:
            self = .delimiter
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF:
            self = .ideograph
        default:
            let props = scalar.properties
            if props.isWhitespace { self = .delimiter }
            else if props.isUppercase { self = .upper }
            else if props.isLowercase { self = .lower }
            else { self = .other }
        }
    }
}
