import Foundation

/// Finds a query in lines of pane text, the way tmux `find-window -C` does, plus a
/// smart-case literal mode for everyday typing.
///
/// - ``PaneContentSyntax/text`` finds a literal substring.
/// - ``PaneContentSyntax/glob`` is tmux's default: the query is a shell glob
///   tested as `*query*` with `fnmatch(3)` (see ``TmuxGlobPattern``).
/// - ``PaneContentSyntax/regex`` is tmux's `-r`. tmux compiles POSIX extended
///   regular expressions; this uses `NSRegularExpression` (ICU), which accepts
///   the same everyday syntax (alternation, groups, `+`, `?`, `{m,n}`, bracket
///   classes including `[[:digit:]]`) but differs at the edges: ICU knows `\d`,
///   `\b` and lazy quantifiers, and POSIX's leftmost-longest alternation becomes
///   ICU's leftmost-first.
///
/// As in tmux's `window_pane_search`, trailing whitespace is trimmed from each line
/// before matching. Case follows ``PaneContentCaseMode``.
public struct PaneContentMatcher: Sendable {
    private enum Compiled: Sendable {
        case empty
        case text(String, caseInsensitive: Bool)
        case glob(TmuxGlobPattern)
        // NSRegularExpression is immutable after creation and documented as safe to
        // use from several threads at once.
        case regex(RegexBox)
    }

    /// Holds a compiled expression so the enum stays `Sendable`.
    private final class RegexBox: @unchecked Sendable {
        // Safe: `NSRegularExpression` is immutable and thread-safe once created.
        let expression: NSRegularExpression

        init(_ expression: NSRegularExpression) {
            self.expression = expression
        }
    }

    private let compiled: Compiled

    /// Compiles `query`.
    ///
    /// - Parameters:
    ///   - query: The text the user typed.
    ///   - syntax: How to read it.
    ///   - caseMode: Whether case matters.
    /// - Throws: ``PaneContentMatcherError/invalidRegex(_:)`` when `syntax` is
    ///   ``PaneContentSyntax/regex`` and the query does not compile.
    public init(query: String, syntax: PaneContentSyntax, caseMode: PaneContentCaseMode) throws {
        guard !query.isEmpty else {
            compiled = .empty
            return
        }
        let caseInsensitive: Bool
        switch caseMode {
        case .smart: caseInsensitive = !query.contains { $0.isUppercase }
        case .ignore: caseInsensitive = true
        case .respect: caseInsensitive = false
        }
        switch syntax {
        case .text:
            compiled = .text(query, caseInsensitive: caseInsensitive)
        case .glob:
            compiled = .glob(TmuxGlobPattern(query, caseInsensitive: caseInsensitive))
        case .regex:
            do {
                let expression = try NSRegularExpression(
                    pattern: query,
                    options: caseInsensitive ? [.caseInsensitive] : []
                )
                compiled = .regex(RegexBox(expression))
            } catch {
                throw PaneContentMatcherError.invalidRegex(error.localizedDescription)
            }
        }
    }

    /// Whether the query is empty and matches nothing.
    public var isEmpty: Bool {
        if case .empty = compiled { return true }
        return false
    }

    /// The first match in `line`, after trimming trailing whitespace.
    ///
    /// - Parameter line: One line of pane text.
    /// - Returns: The matched range in `line`, or `nil`.
    public func firstMatch(in line: String) -> Range<String.Index>? {
        matches(in: line, limit: 1).first
    }

    /// Up to `limit` non-overlapping matches in `line`, left to right.
    ///
    /// - Parameters:
    ///   - line: One line of pane text.
    ///   - limit: The most ranges to return.
    /// - Returns: The matched ranges in `line`.
    public func matches(in line: String, limit: Int) -> [Range<String.Index>] {
        guard limit > 0 else { return [] }
        let trimmedEnd = Self.endTrimmingTrailingWhitespace(line)
        let searchable = line[line.startIndex..<trimmedEnd]
        var ranges: [Range<String.Index>] = []
        switch compiled {
        case .empty:
            return []
        case let .text(query, caseInsensitive):
            var lower = searchable.startIndex
            let options: String.CompareOptions = caseInsensitive ? [.literal, .caseInsensitive] : [.literal]
            while ranges.count < limit,
                  let range = searchable.range(of: query, options: options, range: lower..<searchable.endIndex) {
                ranges.append(range)
                lower = range.isEmpty ? searchable.index(after: range.upperBound) : range.upperBound
                if lower > searchable.endIndex { break }
            }
        case let .glob(pattern):
            let text = String(searchable)
            var offset = 0
            let scalarCount = text.unicodeScalars.count
            while ranges.count < limit, offset <= scalarCount,
                  let range = pattern.firstMatch(in: text, fromScalarOffset: offset) {
                ranges.append(Self.translate(range, from: text, to: line))
                let end = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.upperBound)
                offset = range.isEmpty ? end + 1 : end
            }
        case let .regex(box):
            let text = String(searchable)
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            // Enumerated so matching stops at `limit`, and with progress reports so a
            // backtracking pattern stops when the search that asked for it is cancelled.
            box.expression.enumerateMatches(in: text, options: [.reportProgress], range: nsRange) { result, _, stop in
                if let result, let range = Range(result.range, in: text) {
                    ranges.append(Self.translate(range, from: text, to: line))
                }
                if ranges.count >= limit || Task.isCancelled { stop.pointee = true }
            }
        }
        return ranges
    }

    /// Maps a range in a copy of a prefix of `line` back onto `line` itself.
    private static func translate(_ range: Range<String.Index>, from copy: String, to line: String) -> Range<String.Index> {
        let scalars = copy.unicodeScalars
        let lowerOffset = scalars.distance(from: scalars.startIndex, to: range.lowerBound)
        let length = scalars.distance(from: range.lowerBound, to: range.upperBound)
        let lineScalars = line.unicodeScalars
        let lower = lineScalars.index(lineScalars.startIndex, offsetBy: lowerOffset)
        return lower..<lineScalars.index(lower, offsetBy: length)
    }

    /// Where `line` ends once trailing C `isspace` characters are dropped, as tmux trims.
    private static func endTrimmingTrailingWhitespace(_ line: String) -> String.Index {
        let scalars = line.unicodeScalars
        var end = scalars.endIndex
        while end > scalars.startIndex {
            let previous = scalars.index(before: end)
            let value = scalars[previous].value
            guard value == 0x20 || (0x09...0x0D).contains(value) else { break }
            end = previous
        }
        return end
    }
}
