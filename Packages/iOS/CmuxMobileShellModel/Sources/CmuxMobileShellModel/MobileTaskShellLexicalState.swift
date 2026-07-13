import Foundation

/// Tracks the shell quote context for the outer command and nested command or
/// arithmetic substitutions. Each substitution owns its quotes and comments.
struct MobileTaskShellLexicalState {
    enum Quote {
        case unquoted
        case single
        case double
    }

    private enum ContextKind {
        case root
        case commandSubstitution
        case arithmeticExpansion
    }

    private struct Frame {
        let kind: ContextKind
        var quote = Quote.unquoted
        var escaped = false
        var inComment = false
        var atWordBoundary = true
        var parenthesisDepth = 0
    }

    private var frames = [Frame(kind: .root)]

    var quote: Quote { frames[frames.count - 1].quote }
    var escaped: Bool { frames[frames.count - 1].escaped }
    var inComment: Bool { frames[frames.count - 1].inComment }

    var permitsEnvironmentExpansion: Bool {
        !inComment && !escaped && quote != .single
    }

    var permitsHereDocumentOperator: Bool {
        !inComment
            && !escaped
            && quote == .unquoted
            && frames.last?.kind != .arithmeticExpansion
    }

    var isInArithmeticExpansion: Bool {
        frames.last?.kind == .arithmeticExpansion
    }

    func startsComment(with character: Character) -> Bool {
        let frame = frames[frames.count - 1]
        return frame.quote == .unquoted
            && !frame.escaped
            && character == "#"
            && frame.atWordBoundary
    }

    func startsCommandSubstitution(
        in command: String,
        at index: String.Index,
        through end: String.Index
    ) -> Bool {
        guard permitsEnvironmentExpansion else { return false }
        let suffix = command[index..<end]
        return suffix.hasPrefix("$(") && !suffix.hasPrefix("$((")
    }

    func startsArithmeticExpansion(
        in command: String,
        at index: String.Index,
        through end: String.Index
    ) -> Bool {
        permitsEnvironmentExpansion && command[index..<end].hasPrefix("$((")
    }

    mutating func beginComment() {
        frames[frames.count - 1].inComment = true
    }

    mutating func markExpansion() {
        frames[frames.count - 1].atWordBoundary = false
    }

    /// Consumes a character when no lookahead is available, such as a newline
    /// immediately following a here-document body range.
    mutating func consume(_ character: Character) {
        consumeOrdinaryCharacter(character)
    }

    /// Consumes one lexical token and returns the next unconsumed index.
    /// Substitution openers and arithmetic closers consume multiple characters.
    mutating func advance(
        in command: String,
        from index: String.Index,
        through end: String.Index
    ) -> String.Index {
        let character = command[index]
        let nextIndex = command.index(after: index)

        if startsArithmeticExpansion(in: command, at: index, through: end) {
            markExpansion()
            frames.append(Frame(kind: .arithmeticExpansion))
            return command.index(index, offsetBy: 3)
        }
        if startsCommandSubstitution(in: command, at: index, through: end) {
            markExpansion()
            frames.append(Frame(kind: .commandSubstitution))
            return command.index(index, offsetBy: 2)
        }

        let frameIndex = frames.count - 1
        if !frames[frameIndex].inComment,
           !frames[frameIndex].escaped,
           frames[frameIndex].quote == .unquoted {
            switch frames[frameIndex].kind {
            case .commandSubstitution:
                if character == "(" {
                    frames[frameIndex].parenthesisDepth += 1
                    frames[frameIndex].atWordBoundary = true
                    return nextIndex
                }
                if character == ")" {
                    if frames[frameIndex].parenthesisDepth == 0 {
                        frames.removeLast()
                        markExpansion()
                    } else {
                        frames[frameIndex].parenthesisDepth -= 1
                        frames[frameIndex].atWordBoundary = true
                    }
                    return nextIndex
                }
            case .arithmeticExpansion:
                if character == "(" {
                    frames[frameIndex].parenthesisDepth += 1
                    frames[frameIndex].atWordBoundary = false
                    return nextIndex
                }
                if character == ")" {
                    if frames[frameIndex].parenthesisDepth == 0,
                       nextIndex < end,
                       command[nextIndex] == ")" {
                        frames.removeLast()
                        markExpansion()
                        return command.index(after: nextIndex)
                    }
                    if frames[frameIndex].parenthesisDepth > 0 {
                        frames[frameIndex].parenthesisDepth -= 1
                    }
                    frames[frameIndex].atWordBoundary = false
                    return nextIndex
                }
            case .root:
                break
            }
        }

        consumeOrdinaryCharacter(character)
        return nextIndex
    }

    private mutating func consumeOrdinaryCharacter(_ character: Character) {
        let frameIndex = frames.count - 1
        if frames[frameIndex].inComment {
            if character == "\n" {
                frames[frameIndex].inComment = false
                frames[frameIndex].atWordBoundary = true
            }
            return
        }
        if frames[frameIndex].escaped {
            frames[frameIndex].escaped = false
            frames[frameIndex].atWordBoundary = false
            return
        }
        switch (frames[frameIndex].quote, character) {
        case (.unquoted, "\\"), (.double, "\\"):
            frames[frameIndex].escaped = true
        case (.unquoted, "'"):
            frames[frameIndex].quote = .single
            frames[frameIndex].atWordBoundary = false
        case (.unquoted, "\""):
            frames[frameIndex].quote = .double
            frames[frameIndex].atWordBoundary = false
        case (.single, "'"):
            frames[frameIndex].quote = .unquoted
        case (.double, "\""):
            frames[frameIndex].quote = .unquoted
        case (.unquoted, " "), (.unquoted, "\t"), (.unquoted, "\r"), (.unquoted, "\n"):
            frames[frameIndex].atWordBoundary = true
        case (.unquoted, ";"), (.unquoted, "|"), (.unquoted, "&"),
             (.unquoted, "("), (.unquoted, ")"), (.unquoted, "<"), (.unquoted, ">"):
            frames[frameIndex].atWordBoundary = true
        default:
            if frames[frameIndex].quote == .unquoted {
                frames[frameIndex].atWordBoundary = false
            }
        }
    }
}
