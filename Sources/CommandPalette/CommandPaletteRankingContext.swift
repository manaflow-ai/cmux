import Foundation

/// A single coherent ranking layer for one `(query token, candidate)` pairing.
///
/// `CommandPaletteRankingContext` is the seam through which the command-palette
/// scorer evaluates *word-boundary-aware* signals — the class of match that
/// makes VS Code, Sublime, and Raycast pickers "feel" right: characters that
/// land at the start of a word (after a separator) count for more, runs of
/// consecutive characters are rewarded, and matches smeared across large gaps
/// are penalized.
///
/// It carries the inputs (`tokenChars`, `candidateChars`, `segments`) plus an
/// optional `frecency` bonus, and produces a ``Features`` bag describing the
/// best left-to-right subsequence alignment. New ranking signals can be added
/// to ``Features`` and consumed in ``score()`` without threading new arguments
/// through every call site, so growing the ranking model stays mechanical.
///
/// The score it returns is deliberately a *fallback tier*: it sits below the
/// scorer's exact, prefix, whole-word, and substring ladders so that a
/// boundary-aware fuzzy match never outranks a clean textual match.
struct CommandPaletteRankingContext {
    /// The normalized query token characters being matched.
    let tokenChars: [Character]
    /// The normalized candidate characters being matched against.
    let candidateChars: [Character]
    /// The candidate's word segments (maximal runs between separators).
    let segments: [CommandPaletteFuzzyMatcher.WordSegment]
    /// An optional, already-capped frecency bonus for the candidate.
    ///
    /// Defaults to `0`. Frecency is normally folded into the score upstream via
    /// the engine's history boost; this field lets future ranking signals reach
    /// it inside the context without a new parameter.
    let frecency: Int

    /// The set of candidate indices that begin a word segment.
    ///
    /// A matched character at one of these indices is a *word-boundary* hit.
    private let boundaryStarts: Set<Int>

    /// Creates a ranking context for a token/candidate pairing.
    ///
    /// - Parameters:
    ///   - tokenChars: Normalized query token characters.
    ///   - candidateChars: Normalized candidate characters.
    ///   - segments: The candidate's precomputed word segments.
    ///   - frecency: An optional capped frecency bonus (defaults to `0`).
    init(
        tokenChars: [Character],
        candidateChars: [Character],
        segments: [CommandPaletteFuzzyMatcher.WordSegment],
        frecency: Int = 0
    ) {
        self.tokenChars = tokenChars
        self.candidateChars = candidateChars
        self.segments = segments
        self.frecency = frecency
        self.boundaryStarts = Set(segments.map(\.start))
    }

    /// The computed signals for the best left-to-right subsequence alignment.
    ///
    /// This is the "features bag" the ranking layer scores from. Add new fields
    /// here as more signals are introduced.
    struct Features: Equatable {
        /// The matched candidate indices, in ascending order.
        let matchedIndices: [Int]
        /// How many matched characters land at the start of a word segment.
        let boundaryHits: Int
        /// The total number of skipped characters between matched characters.
        let gapTotal: Int
        /// The longest run of consecutive matched characters.
        let longestRun: Int
        /// Whether the first matched character is at a word boundary.
        let leadingBoundary: Bool
    }

    /// Aligns the token against the candidate as a greedy left-to-right
    /// subsequence and returns the resulting ``Features``.
    ///
    /// - Returns: The match ``Features``, or `nil` if the token is not a
    ///   subsequence of the candidate.
    func boundaryAwareSubsequence() -> Features? {
        guard !tokenChars.isEmpty, tokenChars.count <= candidateChars.count else { return nil }

        var matchedIndices: [Int] = []
        matchedIndices.reserveCapacity(tokenChars.count)
        var boundaryHits = 0
        var gapTotal = 0
        var longestRun = 0
        var currentRun = 0
        var previousMatch = -1
        var searchIndex = 0

        for tokenChar in tokenChars {
            var foundIndex: Int?
            while searchIndex < candidateChars.count {
                if candidateChars[searchIndex] == tokenChar {
                    foundIndex = searchIndex
                    break
                }
                searchIndex += 1
            }
            guard let matchedIndex = foundIndex else { return nil }

            if boundaryStarts.contains(matchedIndex) {
                boundaryHits += 1
            }
            if matchedIndex == previousMatch + 1 {
                currentRun += 1
            } else {
                if previousMatch >= 0 {
                    gapTotal += matchedIndex - previousMatch - 1
                }
                currentRun = 1
            }
            longestRun = max(longestRun, currentRun)
            matchedIndices.append(matchedIndex)
            previousMatch = matchedIndex
            searchIndex = matchedIndex + 1
        }

        return Features(
            matchedIndices: matchedIndices,
            boundaryHits: boundaryHits,
            gapTotal: gapTotal,
            longestRun: longestRun,
            leadingBoundary: matchedIndices.first.map(boundaryStarts.contains) ?? false
        )
    }

    /// The best boundary-aware alignment, but only when it clears the
    /// gap-penalty gate.
    ///
    /// For tokens of four or more characters the match must cover at least two
    /// word boundaries; this is the gap-penalty contract from issue #5033 — it
    /// accepts genuine multi-word abbreviations (`tgsb` → "Toggle Sidebar")
    /// while rejecting characters smeared across an unrelated candidate. Both
    /// scoring and highlight computation share this gate so highlights never
    /// appear for a non-scoring match.
    ///
    /// - Returns: The accepted ``Features``, or `nil` when no acceptable
    ///   boundary-aware subsequence exists.
    func scoredFeatures() -> Features? {
        guard let features = boundaryAwareSubsequence() else { return nil }
        if tokenChars.count >= 4, features.boundaryHits < 2 { return nil }
        return features
    }

    /// Scores the token against the candidate using boundary-aware signals.
    ///
    /// The score rewards word-boundary hits and consecutive runs and penalizes
    /// gaps and trailing length, and sits in a fallback tier below the scorer's
    /// exact/prefix/whole-word/substring ladders.
    ///
    /// - Returns: A positive fallback-tier score, or `nil` when the token does
    ///   not form an acceptable boundary-aware subsequence.
    func score() -> Int? {
        guard let features = scoredFeatures() else { return nil }
        return Self.score(features: features, tokenLength: tokenChars.count, candidateLength: candidateChars.count)
    }

    /// Computes the boundary-aware fallback score from a feature bag.
    ///
    /// Exposed for unit testing the scoring weights independently of alignment.
    static func score(features: Features, tokenLength: Int, candidateLength: Int) -> Int {
        var score = 0
        var previousMatch = -1
        var run = 0
        for matchedIndex in features.matchedIndices {
            score += 80
            if matchedIndex == previousMatch + 1 {
                run += 1
                score += min(180, run * 40)
            } else {
                run = 0
                if previousMatch >= 0 {
                    score -= min(120, (matchedIndex - previousMatch - 1) * 6)
                }
            }
            previousMatch = matchedIndex
        }
        score += features.boundaryHits * 150
        if features.leadingBoundary {
            score += 60
        }
        score -= max(0, candidateLength - tokenLength)
        return max(1, score)
    }
}
