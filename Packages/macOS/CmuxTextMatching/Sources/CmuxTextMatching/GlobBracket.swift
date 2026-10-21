/// One compiled bracket expression of a ``TmuxGlobPattern``, such as `[!a-c[:digit:]]`.
struct GlobBracket: Sendable, Equatable {
    /// One member of the bracket.
    enum Member: Sendable, Equatable {
        case scalar(UInt32)
        case range(UInt32, UInt32)
        case characterClass(GlobCharacterClass)
    }

    let members: [Member]
    let negated: Bool
    let caseInsensitive: Bool

    /// Whether `scalar` is in the bracket, folding case first under `FNM_CASEFOLD` as fnmatch does.
    func matches(_ scalar: UInt32) -> Bool {
        let test = caseInsensitive ? Self.lowercased(scalar) : scalar
        let found = members.contains { member in
            switch member {
            case .scalar(let value): return value == test
            case .range(let lower, let upper): return lower <= test && test <= upper
            case .characterClass(let characterClass): return characterClass.contains(test)
            }
        }
        return found != negated
    }

    /// Parses the bracket that starts after a `[` at `start`.
    ///
    /// - Returns: The bracket and the index after its closing `]`, or `nil` when the
    ///   bracket is malformed (fnmatch reports an error and nothing matches).
    static func parse(_ pattern: [UInt32], from start: Int, caseInsensitive: Bool) -> (GlobBracket, Int)? {
        var index = start
        var negated = false
        if index < pattern.count && (pattern[index] == 0x21 || pattern[index] == 0x5E) {
            negated = true
            index += 1
        }
        let firstMemberIndex = index
        var members: [Member] = []
        let fold: (UInt32) -> UInt32 = { caseInsensitive ? lowercased($0) : $0 }
        while true {
            guard index < pattern.count else { return nil }
            let scalar = pattern[index]
            if scalar == 0x5D && index > firstMemberIndex {
                index += 1
                break
            }
            guard let (start, afterStart) = parseEndpoint(pattern, at: index) else { return nil }
            index = afterStart
            switch start {
            case .characterClass(let characterClass):
                if isRangeDash(pattern, at: index) { return nil }
                members.append(.characterClass(characterClass))
            case .scalar(let lower):
                if isRangeDash(pattern, at: index) {
                    guard let (end, afterEnd) = parseEndpoint(pattern, at: index + 1),
                          case .scalar(let upper) = end else { return nil }
                    index = afterEnd
                    members.append(.range(fold(lower), fold(upper)))
                } else {
                    members.append(.scalar(fold(lower)))
                }
            case .range:
                return nil
            }
        }
        return (GlobBracket(members: members, negated: negated, caseInsensitive: caseInsensitive), index)
    }

    /// A `-` that makes a range: not followed by the end of the pattern or by `]`.
    private static func isRangeDash(_ pattern: [UInt32], at index: Int) -> Bool {
        index + 1 < pattern.count && pattern[index] == 0x2D && pattern[index + 1] != 0x5D
    }

    /// Parses one bracket member: an escaped or plain scalar, `[.x.]`, `[=x=]` or `[:class:]`.
    private static func parseEndpoint(_ pattern: [UInt32], at index: Int) -> (Member, Int)? {
        guard index < pattern.count else { return nil }
        let scalar = pattern[index]
        if scalar == 0x5C {
            guard index + 1 < pattern.count else { return nil }
            return (.scalar(pattern[index + 1]), index + 2)
        }
        if scalar == 0x5B, index + 1 < pattern.count {
            let kind = pattern[index + 1]
            if kind == 0x2E || kind == 0x3D || kind == 0x3A {
                // Find the matching `<kind>]`.
                var close = index + 2
                while close + 1 < pattern.count && !(pattern[close] == kind && pattern[close + 1] == 0x5D) {
                    close += 1
                }
                guard close + 1 < pattern.count else { return nil }
                let body = Array(pattern[(index + 2)..<close])
                let after = close + 2
                if kind == 0x3A {
                    let name = String(String.UnicodeScalarView(body.compactMap(Unicode.Scalar.init)))
                    guard let characterClass = GlobCharacterClass(rawValue: name) else { return nil }
                    return (.characterClass(characterClass), after)
                }
                // Collating symbols and equivalence classes name one character in the C locale.
                guard body.count == 1 else { return nil }
                return (.scalar(body[0]), after)
            }
        }
        return (.scalar(scalar), index + 1)
    }

    /// The lowercase form fnmatch's `towlower` gives one scalar.
    static func lowercased(_ scalar: UInt32) -> UInt32 {
        if scalar <= 127 {
            return (0x41...0x5A).contains(scalar) ? scalar + 32 : scalar
        }
        guard let unicodeScalar = Unicode.Scalar(scalar) else { return scalar }
        let mapped = unicodeScalar.properties.lowercaseMapping.unicodeScalars
        guard mapped.count == 1, let only = mapped.first else { return scalar }
        return only.value
    }
}
