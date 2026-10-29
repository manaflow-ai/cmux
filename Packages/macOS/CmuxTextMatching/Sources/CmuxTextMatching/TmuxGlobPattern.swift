/// A shell glob matched the way tmux matches `find-window` patterns, with `fnmatch(3)`.
///
/// tmux calls `fnmatch(pattern, text, flags)` with `flags` either 0 or
/// `FNM_CASEFOLD` (`find-window -i`). So `*` and `?` match any character,
/// including `/` and a leading `.`; brackets take ranges, `!` or `^` negation, a
/// leading `]` as a literal, POSIX classes such as `[[:digit:]]`, collating
/// symbols (`[[.a.]]`) and equivalence classes (`[[=a=]]`); a backslash escapes
/// the next character. A malformed pattern, such as an unterminated bracket or a
/// trailing backslash, matches nothing, which is how macOS's fnmatch treats it
/// (it reports an error, and tmux treats any non-zero result as no match).
///
/// `find-window` wraps the user's string as `*string*`, so it finds the string
/// anywhere in the line. ``firstMatch(in:)`` reports where, for highlighting: the
/// leftmost starting position, and from there the shortest span the pattern
/// matches. Shortest keeps a highlight like `disk*full` tight instead of running
/// to the last `full` on the line.
///
/// Matching runs as an NFA over the pattern's elements, so it is linear in the
/// text for a given pattern and has no exponential backtracking.
public struct TmuxGlobPattern: Sendable {
    /// One element of a compiled glob.
    private enum Element: Sendable, Equatable {
        case literal(UInt32)
        case anyCharacter
        case anyRun
        case bracket(GlobBracket)
    }

    private let elements: [Element]
    private let caseInsensitive: Bool
    /// Whether the pattern is malformed and therefore matches nothing.
    private let isMalformed: Bool

    /// Compiles `pattern`.
    ///
    /// - Parameters:
    ///   - pattern: The glob, as the user typed it.
    ///   - caseInsensitive: `true` for tmux's `-i` (`FNM_CASEFOLD`).
    public init(_ pattern: String, caseInsensitive: Bool) {
        self.caseInsensitive = caseInsensitive
        let scalars = pattern.unicodeScalars.map(\.value)
        var elements: [Element] = []
        var malformed = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case 0x2A: // *
                if elements.last != .anyRun { elements.append(.anyRun) }
                index += 1
            case 0x3F: // ?
                elements.append(.anyCharacter)
                index += 1
            case 0x5B: // [
                if let (bracket, next) = GlobBracket.parse(scalars, from: index + 1, caseInsensitive: caseInsensitive) {
                    elements.append(.bracket(bracket))
                    index = next
                } else {
                    malformed = true
                    index = scalars.count
                }
            case 0x5C: // backslash
                guard index + 1 < scalars.count else {
                    malformed = true
                    index = scalars.count
                    break
                }
                elements.append(.literal(scalars[index + 1]))
                index += 2
            default:
                elements.append(.literal(scalar))
                index += 1
            }
        }
        self.elements = elements
        self.isMalformed = malformed
    }

    /// Whether the pattern matches all of `text`, exactly as `fnmatch(3)` decides.
    ///
    /// - Parameter text: The text, such as a window name.
    /// - Returns: `true` on a match.
    public func matchesWhole(_ text: String) -> Bool {
        guard !isMalformed else { return false }
        let scalars = text.unicodeScalars.map(\.value)
        return shortestMatchEnd(in: scalars, from: 0, mustReachEnd: true) != nil
    }

    /// Whether `*pattern*` matches `text`, as tmux `find-window` asks.
    ///
    /// - Parameter text: The line or name to search.
    /// - Returns: `true` when the pattern matches somewhere in `text`.
    public func matchesAnywhere(_ text: String) -> Bool {
        firstMatch(in: text) != nil
    }

    /// The span `pattern` matches when tmux tests `*pattern*` against `text`.
    ///
    /// - Parameter text: The line or name to search.
    /// - Returns: The leftmost, then shortest, matching range, or `nil`.
    public func firstMatch(in text: String) -> Range<String.Index>? {
        firstMatch(in: text, fromScalarOffset: 0)
    }

    /// ``firstMatch(in:)`` starting the search at a scalar offset.
    func firstMatch(in text: String, fromScalarOffset startOffset: Int) -> Range<String.Index>? {
        guard !isMalformed else { return nil }
        let scalars = text.unicodeScalars.map(\.value)
        guard startOffset <= scalars.count,
              shortestMatchEnd(in: scalars, from: startOffset, mustReachEnd: false, anyStart: true) != nil
        else { return nil }
        for start in startOffset...scalars.count {
            if let end = shortestMatchEnd(in: scalars, from: start, mustReachEnd: false) {
                let view = text.unicodeScalars
                let lower = view.index(view.startIndex, offsetBy: start)
                let upper = view.index(lower, offsetBy: end - start)
                return lower..<upper
            }
        }
        return nil
    }

    /// Runs the NFA from `start`; returns the first (shortest) end offset where the whole
    /// pattern has matched, or only the text end when `mustReachEnd` is set.
    ///
    /// With `anyStart`, a match may begin at any position at or after `start` (an implicit
    /// leading `*`), which answers "is there a match anywhere" in one linear pass.
    private func shortestMatchEnd(in text: [UInt32], from start: Int, mustReachEnd: Bool, anyStart: Bool = false) -> Int? {
        let count = elements.count
        var states = [Bool](repeating: false, count: count + 1)
        states[0] = true
        closeOverRuns(&states)
        var position = start
        while true {
            if states[count] && (!mustReachEnd || position == text.count) {
                return position
            }
            guard position < text.count else { return nil }
            let char = text[position]
            var next = [Bool](repeating: false, count: count + 1)
            var any = false
            for index in 0..<count where states[index] {
                switch elements[index] {
                case .anyRun:
                    next[index] = true
                    any = true
                case .anyCharacter:
                    next[index + 1] = true
                    any = true
                case .literal(let literal):
                    if literal == char || caseInsensitive && GlobBracket.lowercased(literal) == GlobBracket.lowercased(char) {
                        next[index + 1] = true
                        any = true
                    }
                case .bracket(let bracket):
                    if bracket.matches(char) {
                        next[index + 1] = true
                        any = true
                    }
                }
            }
            if anyStart {
                next[0] = true
                any = true
            }
            guard any else { return nil }
            closeOverRuns(&next)
            states = next
            position += 1
        }
    }

    /// A `*` can match nothing, so a state at a `*` also reaches the element after it.
    private func closeOverRuns(_ states: inout [Bool]) {
        for index in 0..<elements.count where states[index] && elements[index] == .anyRun {
            states[index + 1] = true
        }
    }
}
