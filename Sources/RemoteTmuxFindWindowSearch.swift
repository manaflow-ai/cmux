import CmuxTextMatching
import Foundation

/// Matches one find-window query against window names, pane titles and pane text.
///
/// Matching follows tmux `find-window`. With `.glob` the query is an fnmatch(3)
/// pattern that may match anywhere (tmux wraps it in `*…*`), with `.regex` it is a
/// regular expression, and both apply to names, titles and contents alike. With
/// `.text`, the default for typed input, names and titles are scored with fzf's
/// fuzzy algorithm (extended syntax, smart case) and contents use a literal
/// substring with smart case. tmux's `-C` reads only a pane's visible screen; this
/// reads the full history the caller fetched.
///
/// Pure and `Sendable`, so a model can run it off the main actor.
struct RemoteTmuxFindWindowSearch: Sendable {
    static let maximumContentHitsPerPane = 50
    static let maximumContentHits = 500
    /// Characters of context kept before a content match in its snippet.
    static let snippetLeadingContext = 40
    static let snippetMaximumLength = 160

    let query: String
    let options: RemoteTmuxFindWindowOptions
    private let fuzzy: FzfQuery?
    private let matcher: PaneContentMatcher?

    /// - Throws: ``PaneContentMatcherError`` when a regex does not compile.
    init(query: String, options: RemoteTmuxFindWindowOptions) throws {
        self.query = query
        self.options = options
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            fuzzy = nil
            matcher = nil
        } else {
            fuzzy = options.syntax == .text ? FzfQuery(trimmed, caseMode: options.caseMode) : nil
            let contentQuery = options.syntax == .text ? trimmed : query
            matcher = try PaneContentMatcher(query: contentQuery, syntax: options.syntax, caseMode: options.caseMode)
        }
    }

    /// Whether there is anything to match; an empty query lists windows instead.
    var isEmpty: Bool { matcher == nil }

    /// Window-name and pane-title results, best first. With an empty query, one
    /// row per window in tab order.
    func nameAndTitleResults(in candidates: [RemoteTmuxFindWindowCandidate]) -> [RemoteTmuxFindWindowResult] {
        let ordered = candidates.sorted { $0.order < $1.order }
        var firstPaneByWindow: [String: RemoteTmuxFindWindowCandidate] = [:]
        var windowKeys: [String] = []
        for candidate in ordered {
            let key = Self.windowKey(candidate)
            if firstPaneByWindow[key] == nil {
                firstPaneByWindow[key] = candidate
                windowKeys.append(key)
            }
        }
        guard !isEmpty else {
            return windowKeys.compactMap { key in
                firstPaneByWindow[key].map {
                    RemoteTmuxFindWindowResult(id: "window:\(key)", candidate: $0, match: .window, score: 0)
                }
            }
        }
        var results: [RemoteTmuxFindWindowResult] = []
        if options.matchesWindowNames {
            for key in windowKeys {
                guard let candidate = firstPaneByWindow[key],
                      let hit = match(candidate.windowName) else { continue }
                results.append(RemoteTmuxFindWindowResult(
                    id: "name:\(key)",
                    candidate: candidate,
                    match: .windowName(highlights: hit.highlights),
                    score: hit.score
                ))
            }
        }
        if options.matchesPaneTitles {
            for candidate in ordered {
                // Fuzzy matching skips the host-name default tmux gives every pane,
                // or a host name typed as a query would match all of them. tmux's
                // own glob and regex matching sees the raw title.
                let title = options.syntax == .text ? candidate.intentionalPaneTitle : candidate.paneTitle
                guard let title, !title.isEmpty, let hit = match(title) else { continue }
                results.append(RemoteTmuxFindWindowResult(
                    id: "title:\(candidate.id.hostKey):\(candidate.paneId)",
                    candidate: candidate,
                    match: .paneTitle(title: title, highlights: hit.highlights),
                    score: hit.score
                ))
            }
        }
        return results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.candidate.order < $1.candidate.order
        }
    }

    /// Lines of one pane's text that match, newest first, at most
    /// ``maximumContentHitsPerPane``.
    func contentResults(
        for candidate: RemoteTmuxFindWindowCandidate,
        text: RemoteTmuxPaneText
    ) -> [RemoteTmuxFindWindowResult] {
        guard options.matchesContents, let matcher else { return [] }
        var results: [RemoteTmuxFindWindowResult] = []
        var index = text.lines.endIndex
        // Rows taken by the lines below the one being scanned.
        var rowsBelow = 0
        while index > text.lines.startIndex, results.count < Self.maximumContentHitsPerPane {
            index = text.lines.index(before: index)
            if index & 0x3ff == 0, Task.isCancelled { return results }
            let line = text.lines[index]
            let rows = text.maximumRows(of: line)
            defer { rowsBelow += rows }
            guard let range = matcher.firstMatch(in: line) else { continue }
            let linesFromBottom = text.lines.endIndex - 1 - index
            results.append(RemoteTmuxFindWindowResult(
                id: "line:\(candidate.id.hostKey):\(candidate.paneId):\(linesFromBottom)",
                candidate: candidate,
                match: .content(Self.contentHit(
                    line: line,
                    match: range,
                    linesFromBottom: linesFromBottom,
                    rowsFromBottom: rowsBelow + rows - 1
                )),
                score: 0
            ))
        }
        return results
    }

    /// Name and title results followed by content results in tab order, capped.
    func results(
        candidates: [RemoteTmuxFindWindowCandidate],
        texts: [RemoteTmuxFindWindowCandidate.ID: RemoteTmuxPaneText]
    ) -> [RemoteTmuxFindWindowResult] {
        var results = nameAndTitleResults(in: candidates)
        guard !isEmpty else { return results }
        var contentCount = 0
        for candidate in candidates.sorted(by: { $0.order < $1.order }) {
            guard contentCount < Self.maximumContentHits, let text = texts[candidate.id] else { continue }
            let hits = contentResults(for: candidate, text: text)
                .prefix(Self.maximumContentHits - contentCount)
            contentCount += hits.count
            results.append(contentsOf: hits)
        }
        return results
    }

    private func match(_ text: String) -> (score: Int, highlights: [Range<Int>])? {
        if let fuzzy {
            guard let hit = fuzzy.match(text) else { return nil }
            return (hit.score, Self.characterRanges(scalarPositions: hit.positions, in: text))
        }
        guard let matcher, let range = matcher.firstMatch(in: text) else { return nil }
        return (0, [Self.characterRange(range, in: text)])
    }

    private static func windowKey(_ candidate: RemoteTmuxFindWindowCandidate) -> String {
        "\(candidate.id.hostKey):@\(candidate.windowId)"
    }

    /// Cuts `line` down to a snippet that keeps the match in view.
    ///
    /// Works in whole-character offsets. A glob or regex match can start or end inside
    /// a character (a lone combining mark) or in the line's leading or trailing spaces,
    /// so its bounds are widened to whole characters and every offset is clamped.
    static func contentHit(
        line: String,
        match: Range<String.Index>,
        linesFromBottom: Int,
        rowsFromBottom: Int
    ) -> RemoteTmuxFindWindowContentHit {
        let characters = Array(line)
        let (lower, upper) = characterOffsets(of: match, in: line)
        let firstVisible = characters.firstIndex { !$0.isWhitespace } ?? characters.count
        let visibleEnd = characters.lastIndex { !$0.isWhitespace }.map { $0 + 1 } ?? firstVisible
        let windowEnd = max(visibleEnd, upper)
        let start = min(max(firstVisible, max(lower, firstVisible) - snippetLeadingContext), windowEnd)
        let end = min(start + snippetMaximumLength, windowEnd)
        let prefix = start > firstVisible ? "…" : ""
        let suffix = end < visibleEnd ? "…" : ""
        let snippet = prefix + String(characters[start..<end]) + suffix
        // Counted on the assembled text, so a combining mark that joins the ellipsis
        // shifts the highlight with it.
        func snippetOffset(_ offset: Int) -> Int {
            (prefix + String(characters[start..<min(max(offset, start), end)])).count
        }
        let highlightLower = snippetOffset(lower)
        let highlightUpper = min(snippetOffset(upper), snippet.count)
        return RemoteTmuxFindWindowContentHit(
            snippet: snippet,
            highlights: highlightUpper > highlightLower ? [highlightLower..<highlightUpper] : [],
            matchedText: String(line[match]),
            linesFromBottom: linesFromBottom,
            rowsFromBottom: rowsFromBottom
        )
    }

    /// The character offsets that cover `range`, which may start or end inside a character.
    private static func characterOffsets(of range: Range<String.Index>, in line: String) -> (Int, Int) {
        var lower: Int?
        var upper = 0
        var offset = 0
        var index = line.startIndex
        while index < line.endIndex {
            let next = line.index(after: index)
            if lower == nil, range.lowerBound < next { lower = offset }
            if range.upperBound > index { upper = offset + 1 }
            index = next
            offset += 1
        }
        let start = lower ?? offset
        // An empty range sits at its start.
        return (start, range.isEmpty ? start : max(start, upper))
    }

    /// Character offsets of a `String.Index` range.
    static func characterRange(_ range: Range<String.Index>, in text: String) -> Range<Int> {
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        return lower..<(lower + text.distance(from: range.lowerBound, to: range.upperBound))
    }

    /// Merges fzf's Unicode-scalar positions into character ranges.
    static func characterRanges(scalarPositions: [Int], in text: String) -> [Range<Int>] {
        guard !scalarPositions.isEmpty else { return [] }
        let wanted = Set(scalarPositions)
        var ranges: [Range<Int>] = []
        var scalarOffset = 0
        for (characterOffset, character) in text.enumerated() {
            let scalarCount = character.unicodeScalars.count
            let hit = (scalarOffset..<(scalarOffset + scalarCount)).contains { wanted.contains($0) }
            scalarOffset += scalarCount
            guard hit else { continue }
            if let last = ranges.last, last.upperBound == characterOffset {
                ranges[ranges.count - 1] = last.lowerBound..<(characterOffset + 1)
            } else {
                ranges.append(characterOffset..<(characterOffset + 1))
            }
        }
        return ranges
    }
}
