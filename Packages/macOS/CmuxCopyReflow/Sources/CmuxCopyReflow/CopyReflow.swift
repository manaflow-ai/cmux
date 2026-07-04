import Foundation

extension ReflowOptions {
    /// Reflow text copied from a terminal so that lines an application
    /// *hard-wrapped* to fit the viewport are rejoined into continuous
    /// paragraphs, while structured content (code fences, tables, blockquotes,
    /// nested lists, headings, URLs, and blank lines) is preserved.
    ///
    /// The input is expected to be the selection text as ghostty already
    /// produces it — soft-wrap (autowrap) continuations are already joined
    /// upstream, so this only addresses the residual application-emitted hard
    /// wrapping.
    ///
    /// The transform is intentionally conservative: when there is no clear
    /// wrap signal it leaves lines alone. A wrap signal is either a
    /// continuation indent (a line indented past its paragraph's first line)
    /// or a "full" previous line (one whose length reached the block's wrap
    /// width). It never joins across a line ending in sentence punctuation,
    /// and never width-joins a block narrower than
    /// ``ReflowOptions/minWrapWidth``.
    public func reflow(_ text: String) -> String {
        reflowCopiedText(text)
    }
}

private extension ReflowOptions {
    func reflowCopiedText(_ text: String) -> String {
        if text.isEmpty { return text }

        let hadTrailingNewline = text.hasSuffix("\n")
        // Split on "\n"; normalise CRLF by dropping a trailing "\r" per line.
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }

        // Pass 1: marker-aware fence state per line + common indent over
        // eligible lines.
        var lineKinds = [LineKind]()
        lineKinds.reserveCapacity(rawLines.count)
        var isFenceLine = [Bool](repeating: false, count: rawLines.count)
        do {
            var activeFence: FenceMarker?
            for (i, line) in rawLines.enumerated() {
                let kind = LineKind(line, activeFence: activeFence)
                lineKinds.append(kind)
                if let marker = FenceMarker(trimmedLine: line.drop { $0 == " " || $0 == "\t" }),
                   activeFence == nil {
                    isFenceLine[i] = true
                    activeFence = marker
                } else if activeFence != nil {
                    isFenceLine[i] = true
                    if kind == .fenceDelimiter {
                        activeFence = nil
                    }
                }
            }
        }
        promoteMarkdownTableRows(rawLines, lineKinds: &lineKinds)

        let commonIndent = computeCommonIndent(rawLines, isFenceLine: isFenceLine)

        // Working view of each line: common indent removed and terminal
        // right-padding trimmed. It feeds wrap detection and joined output only.
        let displayStorage: [String] = rawLines.indices.map { i in
            let s = stripColumns(rawLines[i], commonIndent)
            switch lineKinds[i] {
            case .fenceDelimiter, .insideFence:
                return String(s)
            case .blank, .heading, .blockquote, .tableRow, .listItem, .urlLine, .prose:
                return trimTrailingSpaceLike(s)
            }
        }
        let stripped: [Substring] = displayStorage.map { $0[...] }

        // Preserved view of each line: no common-indent stripping. It is emitted
        // when a line never participates in a wrap join.
        let preservedStorage: [String] = rawLines.indices.map { i in
            switch lineKinds[i] {
            case .fenceDelimiter, .insideFence:
                return String(rawLines[i])
            case .blank:
                return ""
            case .heading, .blockquote, .tableRow, .listItem, .urlLine, .prose:
                return trimTrailingSpaceLike(rawLines[i])
            }
        }

        // Pass 2: emit.
        var output: [String] = []
        var para: Paragraph?

        func flush() {
            if let p = para {
                output.append(p.hasJoined ? p.text : p.standaloneText)
                para = nil
            }
        }

        for i in rawLines.indices {
            let line = stripped[i]
            let preservedLine = preservedStorage[i]
            let kind = lineKinds[i]

            switch kind {
            case .fenceDelimiter, .insideFence:
                flush()
                output.append(preservedLine)

            case .blank:
                flush()
                output.append("")

            case .heading, .blockquote, .tableRow:
                // Structural lines are hard breaks and never absorb a continuation.
                flush()
                output.append(preservedLine)

            case .listItem:
                // A list item starts a new output line but opens a paragraph so its
                // own wrapped continuation can rejoin onto it.
                flush()
                para = Paragraph(
                    text: String(line),
                    standaloneText: preservedLine,
                    hasJoined: false,
                    baseIndent: line.indentWidth,
                    isURL: false,
                    prevVisibleLength: line.visibleLength,
                    maxVisibleLength: line.visibleLength,
                    prevEndsTerminator: lastNonSpaceIsTerminator(line),
                    prevHasSpace: line.contains(" "),
                    prevContent: String(line),
                    allowsWidthJoin: true,
                    isProse: false
                )

            case .prose, .urlLine:
                let indent = line.indentWidth
                let standaloneContent = stripDecoration(preservedLine[...])
                let content = stripDecoration(cleanProseWhitespace(line)[...])
                let visLen = line.visibleLength
                let endsTerminator = lastNonSpaceIsTerminator(line)
                let hasSpace = line.contains(" ")

                func openParagraph() {
                    // Prose/URL paragraphs are left-flushed: a leading indent on a
                    // prose line is a terminal-output artifact, not meaningful (only
                    // list items, handled separately, keep their indent). baseIndent
                    // still records the original indent so the s1 continuation-indent
                    // join signal keeps working.
                    para = Paragraph(
                        text: content.trimmingLeadingWhitespace(),
                        standaloneText: standaloneContent,
                        hasJoined: false,
                        baseIndent: indent,
                        isURL: kind == .urlLine,
                        prevVisibleLength: visLen,
                        maxVisibleLength: visLen,
                        prevEndsTerminator: endsTerminator,
                        prevHasSpace: hasSpace,
                        prevContent: content,
                        allowsWidthJoin: commonIndent < 4,
                        isProse: true
                    )
                }

                if var p = para {
                    // s1: an explicit continuation indent (line indented past the
                    //     paragraph's first line).
                    let indentationDelta = indent - p.baseIndent
                    let structuredIndentedCode = indentationDelta > 0
                        && looksLikeStructuredIndentedCode(content, after: p.prevContent)
                    let shortIndentContinuation = indentationDelta <= 2
                        && p.prevHasSpace
                        && startsLowercaseLetter(content)
                    let s1 = indentationDelta > 0
                        && (p.prevVisibleLength >= minWrapWidth || shortIndentContinuation)
                        && !endsIndentedBlock(p.prevContent)
                        && !structuredIndentedCode
                    // s3: a wrapped bare URL continues as a spaceless path fragment.
                    let s3 = p.isURL && startsURLContinuationToken(content)
                    // s4: mid-sentence continuation. The previous line is full
                    //     enough to have wrapped (prose-like, within widthTolerance
                    //     of the candidate paragraph's widest line) and this line
                    //     resumes lowercase or with a command continuation token.
                    //     Uppercase starts, list markers, and digits still do not
                    //     trigger it, which keeps line-oriented output unjoined.
                    let candidateMaxVisibleLength = max(p.maxVisibleLength, visLen)
                    let previousLineWasFull = p.prevVisibleLength >= minWrapWidth
                        && p.prevVisibleLength + max(0, widthTolerance) >= candidateMaxVisibleLength
                    let lowercaseContinuation = startsLowercaseLetter(content)
                        && hasProseContinuationEvidence(
                            previous: p.prevContent,
                            current: content,
                            commonIndent: commonIndent,
                            alreadyJoined: p.hasJoined
                        )
                        && !startsIndependentRecord(content, after: p.prevContent)
                    let commandContinuation = startsCommandContinuationToken(content)
                        && !startsCommandContinuationToken(p.prevContent)
                        && !startsOptionLikeRow(p.prevContent)
                    let s4 = p.prevHasSpace
                        && p.allowsWidthJoin
                        && !structuredIndentedCode
                        && previousLineWasFull
                        && (lowercaseContinuation || commandContinuation)
                    let canJoin = !p.prevEndsTerminator && (s1 || s3 || s4)

                    if canJoin {
                        let joiner = s3 ? "" : " "
                        p.text += joiner + content.trimmingLeadingWhitespace()
                        p.hasJoined = true
                        p.prevVisibleLength = visLen
                        p.maxVisibleLength = max(p.maxVisibleLength, visLen)
                        p.prevEndsTerminator = endsTerminator
                        p.prevHasSpace = hasSpace
                        p.prevContent = content
                        para = p
                    } else {
                        flush()
                        openParagraph()
                    }
                } else {
                    openParagraph()
                }
            }
        }
        flush()

        var result = output.joined(separator: "\n")
        if hadTrailingNewline && !result.hasSuffix("\n") {
            result += "\n"
        }
        return result
    }

    /// Promote loose pipe rows around a Markdown separator row into structural
    /// table rows without treating every shell pipeline as a table.
    func promoteMarkdownTableRows(_ lines: [Substring], lineKinds: inout [LineKind]) {
        guard lines.count == lineKinds.count else { return }
        for i in lines.indices {
            guard isPromotableTableKind(lineKinds[i]),
                  LineKind.isMarkdownTableSeparatorRow(lines[i]) else { continue }

            lineKinds[i] = .tableRow

            let headerIndex = i - 1
            if headerIndex >= 0,
               isPromotableTableKind(lineKinds[headerIndex]),
               LineKind.isMarkdownTableCandidateRow(lines[headerIndex]) {
                lineKinds[headerIndex] = .tableRow
            }

            var bodyIndex = i + 1
            while bodyIndex < lines.count,
                  isPromotableTableKind(lineKinds[bodyIndex]),
                  LineKind.isMarkdownTableCandidateRow(lines[bodyIndex]) {
                lineKinds[bodyIndex] = .tableRow
                bodyIndex += 1
            }
        }
    }

    func isPromotableTableKind(_ kind: LineKind) -> Bool {
        switch kind {
        case .prose, .tableRow:
            return true
        case .blank, .fenceDelimiter, .insideFence, .heading, .blockquote, .listItem, .urlLine:
            return false
        }
    }

    /// Minimum leading-whitespace column count across blank-excluded, fence-excluded
    /// lines. Tabs and spaces each count as one column.
    func computeCommonIndent(_ lines: [Substring], isFenceLine: [Bool]) -> Int {
        var minIndent: Int?
        for (i, line) in lines.enumerated() {
            if isFenceLine[i] { continue }
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.isEmpty { continue } // blank
            let indent = line.indentWidth
            minIndent = min(minIndent ?? indent, indent)
        }
        return minIndent ?? 0
    }

    /// True when the first non-whitespace character is a lowercase letter — the
    /// signal that a line resumes a sentence wrapped from the previous line.
    func startsLowercaseLetter(_ s: String) -> Bool {
        guard let first = s.first(where: { $0 != " " && $0 != "\t" }) else { return false }
        return first.isLowercase && first.isLetter
    }

    /// True when the first non-whitespace character is an uppercase letter — the
    /// signal that a line begins a new sentence/paragraph rather than continuing one.
    func startsUppercaseLetter(_ s: String) -> Bool {
        guard let first = s.first(where: { $0 != " " && $0 != "\t" }) else { return false }
        return first.isUppercase && first.isLetter
    }

    /// True for shell-ish continuation tokens that commonly begin wrapped command
    /// arguments but are not lowercase prose starts.
    func startsCommandContinuationToken(_ s: String) -> Bool {
        let trimmed = s.trimmingLeadingWhitespace()
        if trimmed.hasPrefix("--") { return true }
        guard let first = trimmed.first else { return false }
        if first == "/" { return true }
        if first == "$" {
            let rest = trimmed.dropFirst()
            guard let next = rest.first else { return false }
            return next == "{" || next == "_" || next.isLetter || next.isNumber
        }
        if first == "\"" || first == "'" {
            return true
        }
        return false
    }

    /// True for a spaceless fragment that can safely continue a bare URL.
    func startsURLContinuationToken(_ s: String) -> Bool {
        let trimmed = s.trimmingLeadingWhitespace()
        guard !trimmed.isEmpty,
              !trimmed.contains(" "),
              !trimmed.contains("\t"),
              let first = trimmed.first else { return false }
        return first == "/" || first == "?" || first == "#" || first == "&" || first == "="
    }

    /// Any space-like character that copied terminal text may carry: normal space,
    /// tab, and U+00A0 non-breaking space (the seam padding observed on the clipboard).
    func isSpaceLike(_ ch: Character) -> Bool {
        ch == " " || ch == "\t" || ch == "\u{00A0}"
    }

    /// Normalize a non-fence prose line: keep its leading indent (real spaces/tabs,
    /// for list nesting), then collapse every run of space-like characters in the
    /// remainder to a single normal space, dropping leading and trailing padding.
    /// This turns seam padding (space or non-breaking-space runs) into clean prose.
    func cleanProseWhitespace(_ s: Substring) -> String {
        // Leading indent is real spaces/tabs only; U+00A0 is never meaningful indent.
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == " " || s[idx] == "\t" { idx = s.index(after: idx) }
        var out = String(s[s.startIndex..<idx])
        var pendingSpace = false
        var hasContent = false
        for ch in s[idx...] {
            if isSpaceLike(ch) {
                pendingSpace = true
            } else {
                if pendingSpace && hasContent { out.append(" ") }
                out.append(ch)
                hasContent = true
                pendingSpace = false
            }
        }
        return out
    }

    /// Drop copied terminal padding from the end of a structural line without
    /// changing internal table/list/quote alignment.
    func trimTrailingSpaceLike(_ s: Substring) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let previous = s.index(before: end)
            if isSpaceLike(s[previous]) {
                end = previous
            } else {
                break
            }
        }
        return String(s[s.startIndex..<end])
    }

    /// Lines ending in block-introducing punctuation commonly precede semantic
    /// indentation (`if:`, YAML keys, multiline assignments), not wrapped prose.
    func endsIndentedBlock(_ s: String) -> Bool {
        let trimmed = s.trimmingTrailingWhitespace()
        return trimmed.hasSuffix(":") || trimmed.hasSuffix("=") || trimmed.hasSuffix("{")
            || trimmed.hasSuffix("[") || trimmed.hasSuffix("(")
    }

    /// Drop up to `n` leading space/tab columns.
    func stripColumns(_ line: Substring, _ n: Int) -> Substring {
        var dropped = 0
        var idx = line.startIndex
        while dropped < n, idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            idx = line.index(after: idx)
            dropped += 1
        }
        return line[idx...]
    }

    /// Strip a single leading decoration glyph (and following spaces) if present.
    func stripDecoration(_ line: Substring) -> String {
        guard let first = line.first, decorationCharacters.contains(first) else {
            return String(line)
        }
        let rest = line.dropFirst()
        // Only treat it as decoration when followed by a space or end-of-line, so a
        // glyph that is part of a word is left alone.
        if rest.isEmpty || rest.first == " " {
            return String(rest.drop { $0 == " " })
        }
        return String(line)
    }

    func lastNonSpaceIsTerminator(_ line: Substring) -> Bool {
        guard let last = line.reversed().first(where: { $0 != " " && $0 != "\t" }) else {
            return false
        }
        return sentenceTerminators.contains(last)
    }
}

private struct Paragraph {
    /// Accumulated, emitted text of the paragraph so far.
    var text: String
    /// Original line text to emit if this paragraph never actually joins.
    var standaloneText: String
    /// Whether at least one physical line has been joined into ``text``.
    var hasJoined: Bool
    /// Indent (in columns, post common-indent strip) of the paragraph's first
    /// line. Continuation lines indented past this signal a wrap.
    var baseIndent: Int
    /// Whether the paragraph's first line is a bare URL (joins with no space).
    var isURL: Bool
    /// Visible length of the most recently appended physical line.
    var prevVisibleLength: Int
    /// Widest physical line observed in this paragraph candidate.
    var maxVisibleLength: Int
    /// Whether the most recently appended physical line ends with sentence
    /// punctuation (a hard boundary — never join past it).
    var prevEndsTerminator: Bool
    /// Whether the most recently appended physical line contained a space
    /// (prose-like). Gates the width signal so single-token columns (paths,
    /// URLs, hashes) are not width-joined.
    var prevHasSpace: Bool
    /// Normalized content of the most recently appended physical line.
    var prevContent: String
    /// Whether the paragraph can use width-only joins. Uniform code-block-sized
    /// indentation is preserved unless a stronger continuation-indent signal fires.
    var allowsWidthJoin: Bool
    /// Whether this paragraph is ordinary prose (vs a list item). Only prose
    /// paragraphs participate in blank-line paragraph separation.
    var isProse: Bool
}

private extension String {
    func trimmingLeadingWhitespace() -> String {
        String(drop { $0 == " " || $0 == "\t" })
    }

    func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            if self[previous] == " " || self[previous] == "\t" {
                end = previous
            } else {
                break
            }
        }
        return String(self[startIndex..<end])
    }
}
