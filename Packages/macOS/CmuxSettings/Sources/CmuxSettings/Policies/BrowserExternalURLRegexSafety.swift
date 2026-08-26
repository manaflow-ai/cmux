import Foundation

/// Rejects regex constructs that can make a synchronous URL decision unbounded.
struct BrowserExternalURLRegexSafety: Sendable {
    /// Maximum URL text passed to the ICU matcher on the navigation path.
    let maximumTargetLength = 16_384
    /// Maximum regex expression text accepted by the matcher.
    private let maximumExpressionLength = 8_192
    // Eight quantifiers keep even the worst non-nested optional sequence
    // bounded while covering normal URL rules (`https?`, `.*`, and `\d+`).
    private let maximumQuantifierCount = 8
    private let maximumAlternationCount = 32

    /// Returns whether `expression` has a bounded, supported shape.
    func accepts(_ expression: String) -> Bool {
        guard !expression.isEmpty,
              expression.utf8.prefix(maximumExpressionLength + 1).count <= maximumExpressionLength else {
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
        var fixedCharactersSinceQuantifier: Int?
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
                if !isVariableEscapedAtom(character) {
                    incrementFixed(&fixedCharactersSinceQuantifier)
                }
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
                // Reject all `(?` forms to avoid lookarounds and
                // engine-specific extensions on the synchronous path.
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
                fixedCharactersSinceQuantifier = nil
            case "*", "+", "?", "{":
                var quantifierEndIndex = nextIndex
                if character == "{" {
                    guard let parsedEnd = quantifierEnd(in: expression, from: index) else {
                        return false
                    }
                    quantifierEndIndex = parsedEnd
                }
                guard previousAtom == 1 || previousAtom == 2 else { return false }
                // Quantifying a group that already contains a quantifier or
                // alternation is the common catastrophic-backtracking shape.
                guard !(previousAtom == 2 && previousGroupIsComplex) else { return false }
                if let fixedCharactersSinceQuantifier,
                   fixedCharactersSinceQuantifier < 3 {
                    return false
                }
                quantifierCount += 1
                guard quantifierCount <= maximumQuantifierCount else { return false }
                if !groupHasQuantifier.isEmpty {
                    groupHasQuantifier[groupHasQuantifier.count - 1] = true
                }
                previousAtom = 3
                previousGroupIsComplex = false
                fixedCharactersSinceQuantifier = 0
                index = quantifierEndIndex
                continue
            case "^", "$":
                previousAtom = 0
                previousGroupIsComplex = false
                fixedCharactersSinceQuantifier = nil
            default:
                previousAtom = 1
                previousGroupIsComplex = false
                if character != "." {
                    incrementFixed(&fixedCharactersSinceQuantifier)
                }
            }
            index = nextIndex
        }

        return !isEscaping && !inCharacterClass && groupHasQuantifier.isEmpty
    }

    private func incrementFixed(_ value: inout Int?) {
        if let current = value {
            value = min(current + 1, 3)
        }
    }

    private func isVariableEscapedAtom(_ character: Character) -> Bool {
        "dDsSwW".contains(character)
    }

    private func quantifierEnd(
        in expression: String,
        from start: String.Index
    ) -> String.Index? {
        var end = expression.index(after: start)
        while end < expression.endIndex, expression[end] != "}" {
            end = expression.index(after: end)
        }
        guard end < expression.endIndex else { return nil }

        let bodyStart = expression.index(after: start)
        let body = String(expression[bodyStart..<end])
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              !parts[0].isEmpty,
              parts[0].allSatisfy(\.isNumber),
              let lower = Int(parts[0]),
              lower <= 16_384 else {
            return nil
        }
        if parts.count == 2, !parts[1].isEmpty {
            guard parts[1].allSatisfy(\.isNumber),
                  let upper = Int(parts[1]),
                  upper >= lower,
                  upper <= 16_384 else {
                return nil
            }
        }
        return expression.index(after: end)
    }
}
