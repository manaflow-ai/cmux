import Foundation

/// Rejects regular-expression constructs whose backtracking cost cannot be
/// bounded defensibly for user-authored manifests.
struct CmuxAgentRegexSafetyValidator: Sendable {
    private static let maximumBoundedRepetition = 1_024

    /// Returns whether `pattern` belongs to the supported safe subset.
    static func isSafe(_ pattern: String) -> Bool {
        var parser = Parser(characters: Array(pattern))
        return parser.validate()
    }

    private struct Group {
        var containsQuantifier = false
        var containsAlternation = false
        var currentUnboundedRepetitions = 0
        var maximumUnboundedRepetitions = 0

        mutating func finishAlternative() -> Bool {
            guard currentUnboundedRepetitions <= 1 else { return false }
            maximumUnboundedRepetitions = max(
                maximumUnboundedRepetitions,
                currentUnboundedRepetitions
            )
            currentUnboundedRepetitions = 0
            return true
        }
    }

    private enum Atom {
        case simple
        case group(containsQuantifier: Bool, containsAlternation: Bool)
    }

    private struct Repetition {
        let endIndex: Int
        let maximum: Int?
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var groups = [Group()]
        var lastAtom: Atom?
        var justConsumedQuantifier = false

        mutating func validate() -> Bool {
            while index < characters.count {
                switch characters[index] {
                case "\\":
                    guard consumeEscape() else { return false }
                case "[":
                    guard consumeCharacterClass() else { return false }
                case "(":
                    guard consumeGroupStart() else { return false }
                case ")":
                    guard consumeGroupEnd() else { return false }
                case "|":
                    guard consumeAlternation() else { return false }
                case "*", "+":
                    guard consumeQuantifier(maximum: nil, endIndex: index + 1) else {
                        return false
                    }
                case "?":
                    guard consumeQuantifier(maximum: 1, endIndex: index + 1) else {
                        return false
                    }
                case "{":
                    if let repetition = boundedRepetition(at: index) {
                        guard consumeQuantifier(
                            maximum: repetition.maximum,
                            endIndex: repetition.endIndex
                        ) else {
                            return false
                        }
                    } else {
                        consumeSimpleAtom()
                    }
                default:
                    consumeSimpleAtom()
                }
            }
            guard groups.count == 1 else { return false }
            return groups[0].finishAlternative()
        }

        private mutating func consumeEscape() -> Bool {
            let escapedIndex = index + 1
            guard escapedIndex < characters.count else { return false }
            let escaped = characters[escapedIndex]
            guard !escaped.isNumber,
                  !["k", "g", "Q", "E"].contains(escaped) else {
                return false
            }

            if ["p", "P", "N", "x"].contains(escaped),
               escapedIndex + 1 < characters.count,
               characters[escapedIndex + 1] == "{" {
                var cursor = escapedIndex + 2
                while cursor < characters.count, characters[cursor] != "}" {
                    cursor += 1
                }
                guard cursor < characters.count else { return false }
                index = cursor + 1
            } else {
                index = escapedIndex + 1
            }
            lastAtom = .simple
            justConsumedQuantifier = false
            return true
        }

        private mutating func consumeCharacterClass() -> Bool {
            var cursor = index + 1
            var hasContent = false
            if cursor < characters.count, characters[cursor] == "^" {
                cursor += 1
            }
            while cursor < characters.count {
                let character = characters[cursor]
                if character == "\\" {
                    cursor += 2
                    hasContent = true
                    continue
                }
                // Nested ICU set expressions are intentionally outside the
                // supported subset because they complicate static analysis.
                guard character != "[" else { return false }
                if character == "]", hasContent {
                    index = cursor + 1
                    lastAtom = .simple
                    justConsumedQuantifier = false
                    return true
                }
                hasContent = true
                cursor += 1
            }
            return false
        }

        private mutating func consumeGroupStart() -> Bool {
            if index + 1 < characters.count, characters[index + 1] == "?" {
                if index + 2 < characters.count, characters[index + 2] == ":" {
                    groups.append(Group())
                    index += 3
                    lastAtom = nil
                    justConsumedQuantifier = false
                    return true
                }
                guard let declaration = inlineFlagDeclaration(at: index + 2) else {
                    return false
                }
                index = declaration.endIndex
                justConsumedQuantifier = false
                if declaration.opensGroup {
                    groups.append(Group())
                    lastAtom = nil
                }
                return true
            }
            groups.append(Group())
            index += 1
            lastAtom = nil
            justConsumedQuantifier = false
            return true
        }

        private func inlineFlagDeclaration(at startIndex: Int) -> (
            endIndex: Int,
            opensGroup: Bool
        )? {
            var cursor = startIndex
            var hasFlag = false
            while cursor < characters.count {
                let character = characters[cursor]
                if ["i", "m", "s", "-"].contains(character) {
                    hasFlag = hasFlag || character != "-"
                    cursor += 1
                    continue
                }
                guard hasFlag else { return nil }
                if character == ")" {
                    return (cursor + 1, false)
                }
                if character == ":" {
                    return (cursor + 1, true)
                }
                return nil
            }
            return nil
        }

        private mutating func consumeGroupEnd() -> Bool {
            guard groups.count > 1 else { return false }
            var group = groups.removeLast()
            guard group.finishAlternative() else { return false }
            let parentIndex = groups.index(before: groups.endIndex)
            groups[parentIndex].containsQuantifier = groups[parentIndex].containsQuantifier
                || group.containsQuantifier
            groups[parentIndex].containsAlternation = groups[parentIndex].containsAlternation
                || group.containsAlternation
            groups[parentIndex].currentUnboundedRepetitions += group.maximumUnboundedRepetitions
            guard groups[parentIndex].currentUnboundedRepetitions <= 1 else { return false }
            lastAtom = .group(
                containsQuantifier: group.containsQuantifier,
                containsAlternation: group.containsAlternation
            )
            justConsumedQuantifier = false
            index += 1
            return true
        }

        private mutating func consumeAlternation() -> Bool {
            let groupIndex = groups.index(before: groups.endIndex)
            guard groups[groupIndex].finishAlternative() else { return false }
            groups[groupIndex].containsAlternation = true
            lastAtom = nil
            justConsumedQuantifier = false
            index += 1
            return true
        }

        private mutating func consumeQuantifier(
            maximum: Int?,
            endIndex: Int
        ) -> Bool {
            guard let lastAtom, !justConsumedQuantifier else { return false }
            var finalEndIndex = endIndex
            var isPossessive = false
            if finalEndIndex < characters.count {
                switch characters[finalEndIndex] {
                case "+":
                    // Possessive quantifiers never give characters back to a
                    // later atom, so sequential possessive repetitions do not
                    // compound the backtracking search space.
                    isPossessive = true
                    finalEndIndex += 1
                case "?":
                    // Lazy repetitions are valid ICU syntax, but their search
                    // shape is deliberately outside this statically bounded
                    // subset.
                    return false
                default:
                    break
                }
            }
            if case let .group(containsQuantifier, containsAlternation) = lastAtom,
               maximum.map({ $0 > 1 }) ?? true,
               containsQuantifier || containsAlternation {
                return false
            }
            if let maximum, maximum > CmuxAgentRegexSafetyValidator.maximumBoundedRepetition {
                return false
            }
            let groupIndex = groups.index(before: groups.endIndex)
            groups[groupIndex].containsQuantifier = true
            if maximum == nil, !isPossessive {
                groups[groupIndex].currentUnboundedRepetitions += 1
                guard groups[groupIndex].currentUnboundedRepetitions <= 1 else {
                    return false
                }
            }
            justConsumedQuantifier = true
            index = finalEndIndex
            return true
        }

        private func boundedRepetition(at startIndex: Int) -> Repetition? {
            var cursor = startIndex + 1
            let minimumStart = cursor
            while cursor < characters.count, characters[cursor].isNumber {
                cursor += 1
            }
            guard cursor > minimumStart else { return nil }
            let minimum = Int(String(characters[minimumStart..<cursor]))
            guard let minimum else { return nil }
            if cursor < characters.count, characters[cursor] == "}" {
                return Repetition(endIndex: cursor + 1, maximum: minimum)
            }
            guard cursor < characters.count, characters[cursor] == "," else {
                return nil
            }
            cursor += 1
            let maximumStart = cursor
            while cursor < characters.count, characters[cursor].isNumber {
                cursor += 1
            }
            guard cursor < characters.count, characters[cursor] == "}" else {
                return nil
            }
            if cursor == maximumStart {
                return Repetition(endIndex: cursor + 1, maximum: nil)
            }
            guard let maximum = Int(String(characters[maximumStart..<cursor])),
                  maximum >= minimum else {
                return nil
            }
            return Repetition(endIndex: cursor + 1, maximum: maximum)
        }

        private mutating func consumeSimpleAtom() {
            lastAtom = .simple
            justConsumedQuantifier = false
            index += 1
        }
    }
}
