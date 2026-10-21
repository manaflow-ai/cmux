// Ported from fzf, Copyright (c) 2013-2026 Junegunn Choi, MIT License.
// https://github.com/junegunn/fzf/blob/master/src/algo/algo.go

/// One of fzf's scoring schemes (`--scheme`), which tune the word-boundary bonuses.
///
/// ``default`` is what fzf uses unless told otherwise and is right for names and
/// titles. ``path`` favors path segments; ``history`` stops favoring whitespace
/// boundaries, as fzf does for shell history.
public struct FzfScheme: Sendable, Equatable {
    /// Bonus for a match at the start of the text or right after whitespace.
    let bonusBoundaryWhite: Int
    /// Bonus for a match right after a delimiter character.
    let bonusBoundaryDelimiter: Int
    /// Characters that count as delimiters (`/,:;|` by default).
    let delimiterScalars: Set<UInt32>
    /// The class assumed before the first character of the text.
    let initialCharClass: FzfCharClass
    /// Character classes for the ASCII range, indexed by scalar value.
    let asciiCharClasses: [FzfCharClass]
    /// `bonusFor(prev, cls)` for every class pair, row-major by previous class.
    let bonusMatrix: [Int]

    /// fzf's default scheme.
    public static let `default` = FzfScheme(
        bonusBoundaryWhite: FzfAlgorithm.bonusBoundary + 2,
        bonusBoundaryDelimiter: FzfAlgorithm.bonusBoundary + 1,
        delimiters: "/,:;|",
        initialCharClass: .white
    )

    /// fzf's `--scheme=path`.
    public static let path = FzfScheme(
        bonusBoundaryWhite: FzfAlgorithm.bonusBoundary,
        bonusBoundaryDelimiter: FzfAlgorithm.bonusBoundary + 1,
        delimiters: "/",
        initialCharClass: .delimiter
    )

    /// fzf's `--scheme=history`.
    public static let history = FzfScheme(
        bonusBoundaryWhite: FzfAlgorithm.bonusBoundary,
        bonusBoundaryDelimiter: FzfAlgorithm.bonusBoundary,
        delimiters: "/,:;|",
        initialCharClass: .white
    )

    private init(
        bonusBoundaryWhite: Int,
        bonusBoundaryDelimiter: Int,
        delimiters: String,
        initialCharClass: FzfCharClass
    ) {
        self.bonusBoundaryWhite = bonusBoundaryWhite
        self.bonusBoundaryDelimiter = bonusBoundaryDelimiter
        let delimiterScalars = Set(delimiters.unicodeScalars.map(\.value))
        self.delimiterScalars = delimiterScalars
        self.initialCharClass = initialCharClass
        let whiteScalars: Set<UInt32> = [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]
        self.asciiCharClasses = (0...127).map { value -> FzfCharClass in
            let scalar = UInt32(value)
            switch scalar {
            case 0x61...0x7A: return .lower
            case 0x41...0x5A: return .upper
            case 0x30...0x39: return .number
            default:
                if whiteScalars.contains(scalar) { return .white }
                if delimiterScalars.contains(scalar) { return .delimiter }
                return .nonWord
            }
        }
        var matrix: [Int] = []
        let count = FzfCharClass.allCases.count
        matrix.reserveCapacity(count * count)
        for previous in FzfCharClass.allCases {
            for current in FzfCharClass.allCases {
                matrix.append(Self.bonusFor(
                    previous: previous,
                    current: current,
                    bonusBoundaryWhite: bonusBoundaryWhite,
                    bonusBoundaryDelimiter: bonusBoundaryDelimiter
                ))
            }
        }
        self.bonusMatrix = matrix
    }

    /// fzf's `bonusFor`: the bonus for a character of class `current` after one of class `previous`.
    private static func bonusFor(
        previous: FzfCharClass,
        current: FzfCharClass,
        bonusBoundaryWhite: Int,
        bonusBoundaryDelimiter: Int
    ) -> Int {
        if current.rawValue >= FzfCharClass.nonWord.rawValue {
            switch previous {
            case .white: return bonusBoundaryWhite
            case .delimiter: return bonusBoundaryDelimiter
            case .nonWord: return FzfAlgorithm.bonusBoundary
            default: break
            }
        }
        if previous == .lower && current == .upper || previous != .number && current == .number {
            return FzfAlgorithm.bonusCamel123
        }
        switch current {
        case .nonWord, .delimiter: return FzfAlgorithm.bonusNonWord
        case .white: return bonusBoundaryWhite
        default: return 0
        }
    }

    /// The bonus for a character of class `current` following one of class `previous`.
    func bonus(previous: FzfCharClass, current: FzfCharClass) -> Int {
        bonusMatrix[previous.rawValue * FzfCharClass.allCases.count + current.rawValue]
    }

    /// fzf's `charClassOf`.
    func charClass(of scalar: UInt32) -> FzfCharClass {
        if scalar <= 127 { return asciiCharClasses[Int(scalar)] }
        guard let unicodeScalar = Unicode.Scalar(scalar) else { return .nonWord }
        let properties = unicodeScalar.properties
        switch properties.generalCategory {
        case .lowercaseLetter: return .lower
        case .uppercaseLetter: return .upper
        case .decimalNumber, .letterNumber, .otherNumber: return .number
        case .titlecaseLetter, .modifierLetter, .otherLetter: return .letter
        default:
            if properties.isWhitespace { return .white }
            if delimiterScalars.contains(scalar) { return .delimiter }
            return .nonWord
        }
    }
}
