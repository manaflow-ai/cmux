// Ported from fzf, Copyright (c) 2013-2026 Junegunn Choi, MIT License.
// https://github.com/junegunn/fzf/blob/master/src/pattern.go

/// A query in fzf's extended-search syntax, scored with fzf's V2 algorithm.
///
/// This is what fzf does with its default options (`--extended --algo=v2
/// --smart-case`), minus diacritic folding:
///
/// - Spaces separate terms, and every term must match. `\ ` is a literal space.
/// - `a | b` matches when either term does.
/// - A plain term is fuzzy. `'abc` is an exact substring, `'abc'` an exact
///   substring on word boundaries, `^abc` a prefix, `abc$` a suffix and `^abc$`
///   the whole text.
/// - `!abc` excludes texts containing `abc` (an exact match, as in fzf).
/// - Each term respects case only when it contains an uppercase letter, unless a
///   ``PaneContentCaseMode`` other than `.smart` says otherwise.
///
/// The score of a match is the sum of the scores of the terms that matched.
///
/// ```swift
/// let query = FzfQuery("srv log !test")
/// query.match("server-logs")   // matches
/// query.match("test-server.log") // nil
/// ```
public struct FzfQuery: Sendable {
    /// The parsed terms: every inner array is one `|` group, and every group must match.
    let termSets: [[FzfQueryTerm]]
    let algorithm: FzfAlgorithm

    /// Parses `query`.
    ///
    /// - Parameters:
    ///   - query: The text the user typed.
    ///   - scheme: The fzf scoring scheme.
    ///   - caseMode: `.smart` is fzf's smart case per term; `.ignore` and `.respect`
    ///     apply to every term.
    public init(_ query: String, scheme: FzfScheme = .default, caseMode: PaneContentCaseMode = .smart) {
        self.algorithm = FzfAlgorithm(scheme: scheme)
        self.termSets = Self.parseTerms(Self.trimmed(query), caseMode: caseMode)
    }

    /// Whether the query has no terms and so matches everything.
    public var isEmpty: Bool { termSets.isEmpty }

    /// Matches `text` against every term group.
    ///
    /// - Parameter text: The candidate, such as a window name.
    /// - Returns: The total score and the characters to highlight, or `nil` when a group
    ///   does not match. An empty query matches with score 0 and nothing highlighted.
    public func match(_ text: String) -> FzfQueryMatch? {
        var totalScore = 0
        var positions: Set<Int> = []
        for termSet in termSets {
            var matched = false
            var setScore = 0
            var setPositions: [Int] = []
            for term in termSet {
                if let result = run(term, on: text) {
                    if term.inverse { continue }
                    setScore = result.score
                    setPositions = result.positions.isEmpty ? Array(result.start..<result.end) : result.positions
                    matched = true
                    break
                } else if term.inverse {
                    setScore = 0
                    setPositions = []
                    matched = true
                    continue
                }
            }
            guard matched else { return nil }
            totalScore += setScore
            positions.formUnion(setPositions)
        }
        return FzfQueryMatch(score: totalScore, positions: positions.sorted())
    }

    private func run(_ term: FzfQueryTerm, on text: String) -> FzfMatchResult? {
        let sensitive = term.caseSensitive
        switch term.type {
        case .fuzzy:
            return algorithm.fuzzyMatchV2(text: text, pattern: term.text, caseSensitive: sensitive)
        case .exact:
            return algorithm.exactMatchNaive(text: text, pattern: term.text, caseSensitive: sensitive)
        case .exactBoundary:
            return algorithm.exactMatchBoundary(text: text, pattern: term.text, caseSensitive: sensitive)
        case .prefix:
            return algorithm.prefixMatch(text: text, pattern: term.text, caseSensitive: sensitive)
        case .suffix:
            return algorithm.suffixMatch(text: text, pattern: term.text, caseSensitive: sensitive)
        case .equal:
            return algorithm.equalMatch(text: text, pattern: term.text, caseSensitive: sensitive)
        }
    }

    /// fzf's BuildPattern trimming: leading spaces, and trailing spaces unless escaped.
    static func trimmed(_ query: String) -> String {
        var text = Substring(query)
        while text.first == " " { text.removeFirst() }
        while text.hasSuffix(" ") && !text.hasSuffix("\\ ") { text.removeLast() }
        return String(text)
    }

    /// fzf's `parseTerms` with `fuzzy` on, and smart case unless `caseMode` overrides it.
    static func parseTerms(_ query: String, caseMode: PaneContentCaseMode = .smart) -> [[FzfQueryTerm]] {
        let escaped = query.replacingOccurrences(of: "\\ ", with: "\t")
        let tokens = escaped.split(separator: " ", omittingEmptySubsequences: true)
        var sets: [[FzfQueryTerm]] = []
        var set: [FzfQueryTerm] = []
        var switchSet = false
        var afterBar = false
        for token in tokens {
            var text = token.replacingOccurrences(of: "\t", with: " ")
            var type = FzfTermType.fuzzy
            var inverse = false
            let lowerText = text.lowercased()
            let caseSensitive: Bool
            switch caseMode {
            case .smart: caseSensitive = text != lowerText
            case .ignore: caseSensitive = false
            case .respect: caseSensitive = true
            }
            if !caseSensitive { text = lowerText }

            if !set.isEmpty && !afterBar && text == "|" {
                switchSet = false
                afterBar = true
                continue
            }
            afterBar = false

            if text.hasPrefix("!") {
                inverse = true
                type = .exact
                text.removeFirst()
            }
            if text != "$" && text.hasSuffix("$") {
                type = .suffix
                text.removeLast()
            }
            if text.utf8.count > 2 && text.hasPrefix("'") && text.hasSuffix("'") {
                type = .exactBoundary
                text = String(text.dropFirst().dropLast())
            } else if text.hasPrefix("'") {
                // Flip exactness.
                type = inverse ? .fuzzy : .exact
                text.removeFirst()
            } else if text.hasPrefix("^") {
                type = type == .suffix ? .equal : .prefix
                text.removeFirst()
            }

            if !text.isEmpty {
                if switchSet {
                    sets.append(set)
                    set = []
                }
                set.append(FzfQueryTerm(type: type, inverse: inverse, text: text, caseSensitive: caseSensitive))
                switchSet = true
            }
        }
        if !set.isEmpty { sets.append(set) }
        return sets
    }
}
