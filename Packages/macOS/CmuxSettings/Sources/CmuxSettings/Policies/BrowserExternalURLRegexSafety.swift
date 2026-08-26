import Foundation

/// Rejects regex constructs that can make a synchronous URL decision unbounded.
struct BrowserExternalURLRegexSafety: Equatable, Sendable {
    /// Maximum URL text passed to the ICU matcher on the navigation path.
    let maximumTargetLength = 16_384
    /// Maximum regex expression text accepted by the matcher.
    private let maximumExpressionLength = 8_192
    private let maximumQuantifierCount = 32
    private let maximumAlternationCount = 32

    /// Returns whether `expression` has a bounded, supported shape.
    func accepts(_ expression: String) -> Bool {
        guard !expression.isEmpty,
              expression.prefix(maximumExpressionLength + 1).count <= maximumExpressionLength else {
            return false
        }

        var groupHasQuantifier: [Bool] = []
        var groupHasAlternation: [Bool] = []
        var previousAtom: UInt8 = 0 // 0 = none, 1 = ordinary, 2 = group, 3 = quantified
        var previousGroupIsComplex = false
        var isEscaping = false
        var inCharacterClass = false
        var quantifierCount = 0
        var alternationCount = 0
        var index = expression.startIndex

        while index < expression.endIndex {
            let character = expression[index]
            let nextIndex = expression.index(after: index)

            if isEscaping {
                // Backreferences and subroutine calls can force non-local,
                // highly backtracking matches; URL rules do not need them.
                if character.isNumber || character == "k" || character == "K" || character == "g" || character == "G" {
                    return false
                }
                isEscaping = false
                previousAtom = 1
                previousGroupIsComplex = false
                index = nextIndex
                continue
            }

            if character == "\\" {
                isEscaping = true
                index = nextIndex
                continue
            }

            if inCharacterClass {
                if character == "]" {
                    inCharacterClass = false
                    previousAtom = 1
                    previousGroupIsComplex = false
                }
                index = nextIndex
                continue
            }

            switch character {
            case "[":
                inCharacterClass = true
                previousAtom = 1
                previousGroupIsComplex = false
            case "(":
                // Non-capturing groups are harmless, but rejecting all `(?`
                // forms avoids lookarounds and engine-specific extensions.
                if nextIndex < expression.endIndex, expression[nextIndex] == "?" {
                    return false
                }
                groupHasQuantifier.append(false)
                groupHasAlternation.append(false)
                previousAtom = 0
                previousGroupIsComplex = false
            case ")":
                guard let hasQuantifier = groupHasQuantifier.popLast(),
                      let hasAlternation = groupHasAlternation.popLast() else {
                    return false
                }
                if !groupHasQuantifier.isEmpty {
                    groupHasQuantifier[groupHasQuantifier.count - 1] =
                        groupHasQuantifier[groupHasQuantifier.count - 1] || hasQuantifier
                    groupHasAlternation[groupHasAlternation.count - 1] =
                        groupHasAlternation[groupHasAlternation.count - 1] || hasAlternation
                }
                previousAtom = 2
                previousGroupIsComplex = hasQuantifier || hasAlternation
            case "|":
                alternationCount += 1
                guard alternationCount <= maximumAlternationCount else { return false }
                if !groupHasAlternation.isEmpty {
                    groupHasAlternation[groupHasAlternation.count - 1] = true
                }
                previousAtom = 0
                previousGroupIsComplex = false
            case "*", "+", "?", "{":
                guard previousAtom == 1 || previousAtom == 2 else { return false }
                // Quantifying a group that already contains a quantifier or
                // alternation is the common catastrophic-backtracking shape.
                guard !(previousAtom == 2 && previousGroupIsComplex) else { return false }
                quantifierCount += 1
                guard quantifierCount <= maximumQuantifierCount else { return false }
                if !groupHasQuantifier.isEmpty {
                    groupHasQuantifier[groupHasQuantifier.count - 1] = true
                }
                previousAtom = 3
                previousGroupIsComplex = false
            case "^", "$":
                previousAtom = 0
                previousGroupIsComplex = false
            default:
                previousAtom = 1
                previousGroupIsComplex = false
            }
            index = nextIndex
        }

        return !isEscaping && !inCharacterClass && groupHasQuantifier.isEmpty
    }
}
