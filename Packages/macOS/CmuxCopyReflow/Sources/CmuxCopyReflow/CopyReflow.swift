import Foundation

/// Reflow text copied from a terminal so that lines an application
/// *hard-wrapped* to fit the viewport are rejoined into continuous paragraphs,
/// while structured content (code fences, tables, blockquotes, nested lists,
/// headings, URLs, and blank lines) is preserved.
///
/// The input is expected to be the selection text as ghostty already produces
/// it — soft-wrap (autowrap) continuations are already joined upstream, so this
/// only addresses the residual application-emitted hard wrapping.
///
/// The transform is intentionally conservative (see ``ReflowOptions``): when
/// there is no clear wrap signal it leaves lines alone. A wrap signal is either
/// a continuation indent (a line indented past its paragraph's first line) or a
/// "full" previous line (one whose length reached the block's wrap width). It
/// never joins across a line ending in sentence punctuation, and never
/// width-joins a block narrower than ``ReflowOptions/minWrapWidth``.
public nonisolated func reflowCopiedText(
    _ text: String,
    options: ReflowOptions = .default
) -> String {
    if text.isEmpty { return text }

    let hadTrailingNewline = text.hasSuffix("\n")
    // Split on "\n"; normalise CRLF by dropping a trailing "\r" per line.
    let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }

    // Pass 1: fence state per line + common indent over eligible lines.
    var insideFenceFlags = [Bool](repeating: false, count: rawLines.count)
    var isFenceLine = [Bool](repeating: false, count: rawLines.count)
    do {
        var inside = false
        for (i, line) in rawLines.enumerated() {
            let kind = LineClassifier.classify(line, insideFence: inside)
            insideFenceFlags[i] = inside
            if kind == .fenceDelimiter {
                isFenceLine[i] = true
                inside.toggle()
            } else if inside {
                isFenceLine[i] = true
            }
        }
    }

    let commonIndent = computeCommonIndent(rawLines, isFenceLine: isFenceLine)

    // Cleaned view of each line (common indent removed, relative indent kept).
    // Outside fenced code, normalize whitespace: terminal copy carries padding as
    // runs of spaces AND U+00A0 non-breaking spaces (at soft-wrap seams), which
    // render as wide gaps. Collapse every internal whitespace run to a single
    // normal space and drop leading/trailing padding, preserving real list indent.
    // Fence bodies are preserved verbatim.
    let cleanedStorage: [String] = rawLines.indices.map { i in
        let s = stripColumns(rawLines[i], commonIndent)
        return isFenceLine[i] ? String(s) : cleanProseWhitespace(s)
    }
    let stripped: [Substring] = cleanedStorage.map { $0[...] }

    // Pass 2: emit.
    var output: [String] = []
    var para: Paragraph?

    func flush() {
        if let p = para {
            output.append(p.text)
            para = nil
        }
    }

    for i in rawLines.indices {
        let raw = rawLines[i]
        let line = stripped[i]
        let kind = LineClassifier.classify(raw, insideFence: insideFenceFlags[i])

        switch kind {
        case .fenceDelimiter, .insideFence:
            flush()
            output.append(String(line))

        case .blank:
            flush()
            output.append("")

        case .heading, .blockquote, .tableRow:
            // Structural lines are hard breaks and never absorb a continuation.
            flush()
            output.append(String(line))

        case .listItem:
            // A list item starts a new output line but opens a paragraph so its
            // own wrapped continuation can rejoin onto it.
            flush()
            para = Paragraph(
                text: String(line),
                baseIndent: LineClassifier.indentWidth(of: line),
                isURL: false,
                prevVisibleLength: LineClassifier.visibleLength(of: line),
                prevEndsTerminator: lastNonSpaceIsTerminator(line, options: options),
                prevHasSpace: line.contains(" ")
            )

        case .prose, .urlLine:
            let indent = LineClassifier.indentWidth(of: line)
            let content = stripDecoration(line, options: options)
            let visLen = LineClassifier.visibleLength(of: line)
            let endsTerminator = lastNonSpaceIsTerminator(line, options: options)
            let hasSpace = line.contains(" ")

            func openParagraph() {
                para = Paragraph(
                    text: content,
                    baseIndent: indent,
                    isURL: kind == .urlLine,
                    prevVisibleLength: visLen,
                    prevEndsTerminator: endsTerminator,
                    prevHasSpace: hasSpace
                )
            }

            if var p = para {
                // s1: an explicit continuation indent (line indented past the
                //     paragraph's first line).
                let s1 = indent > p.baseIndent
                // s3: a wrapped bare URL continues as a spaceless path fragment.
                let s3 = p.isURL && !content.contains(" ")
                // s4: mid-sentence continuation. The previous line is long enough
                //     to have wrapped (>= minWrapWidth, prose-like) and this line
                //     resumes lowercase. Lines starting uppercase, with a marker,
                //     or a digit (sentences, lists, logs, paths) do not trigger it,
                //     which keeps line-oriented output unjoined.
                let s4 = p.prevHasSpace
                    && p.prevVisibleLength >= options.minWrapWidth
                    && startsLowercaseLetter(content)
                let canJoin = !p.prevEndsTerminator && (s1 || s3 || s4)

                if canJoin {
                    let joiner = p.isURL ? "" : " "
                    p.text += joiner + content.trimmingLeadingWhitespace()
                    p.prevVisibleLength = visLen
                    p.prevEndsTerminator = endsTerminator
                    p.prevHasSpace = hasSpace
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

// MARK: - Internals

private struct Paragraph {
    /// Accumulated, emitted text of the paragraph so far.
    var text: String
    /// Indent (in columns, post common-indent strip) of the paragraph's first
    /// line. Continuation lines indented past this signal a wrap.
    var baseIndent: Int
    /// Whether the paragraph's first line is a bare URL (joins with no space).
    var isURL: Bool
    /// Visible length of the most recently appended physical line.
    var prevVisibleLength: Int
    /// Whether the most recently appended physical line ends with sentence
    /// punctuation (a hard boundary — never join past it).
    var prevEndsTerminator: Bool
    /// Whether the most recently appended physical line contained a space
    /// (prose-like). Gates the width signal so single-token columns (paths,
    /// URLs, hashes) are not width-joined.
    var prevHasSpace: Bool
}

/// Minimum leading-whitespace column count across blank-excluded, fence-excluded
/// lines. Tabs and spaces each count as one column.
private func computeCommonIndent(_ lines: [Substring], isFenceLine: [Bool]) -> Int {
    var minIndent: Int?
    for (i, line) in lines.enumerated() {
        if isFenceLine[i] { continue }
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.isEmpty { continue } // blank
        let indent = LineClassifier.indentWidth(of: line)
        minIndent = min(minIndent ?? indent, indent)
    }
    return minIndent ?? 0
}

/// True when the first non-whitespace character is a lowercase letter — the
/// signal that a line resumes a sentence wrapped from the previous line.
private func startsLowercaseLetter(_ s: String) -> Bool {
    guard let first = s.first(where: { $0 != " " && $0 != "\t" }) else { return false }
    return first.isLowercase && first.isLetter
}

/// Any space-like character that copied terminal text may carry: normal space,
/// tab, and U+00A0 non-breaking space (the seam padding observed on the clipboard).
private func isSpaceLike(_ ch: Character) -> Bool {
    ch == " " || ch == "\t" || ch == "\u{00A0}"
}

/// Normalize a non-fence prose line: keep its leading indent (real spaces/tabs,
/// for list nesting), then collapse every run of space-like characters in the
/// remainder to a single normal space, dropping leading and trailing padding.
/// This turns seam padding (space or non-breaking-space runs) into clean prose.
private func cleanProseWhitespace(_ s: Substring) -> String {
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

/// Drop up to `n` leading space/tab columns.
private func stripColumns(_ line: Substring, _ n: Int) -> Substring {
    var dropped = 0
    var idx = line.startIndex
    while dropped < n, idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
        idx = line.index(after: idx)
        dropped += 1
    }
    return line[idx...]
}

/// Strip a single leading decoration glyph (and following spaces) if present.
private func stripDecoration(_ line: Substring, options: ReflowOptions) -> String {
    guard let first = line.first, options.decorationCharacters.contains(first) else {
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

private func lastNonSpaceIsTerminator(_ line: Substring, options: ReflowOptions) -> Bool {
    guard let last = line.reversed().first(where: { $0 != " " && $0 != "\t" }) else {
        return false
    }
    return options.sentenceTerminators.contains(last)
}

private extension String {
    func trimmingLeadingWhitespace() -> String {
        String(drop { $0 == " " || $0 == "\t" })
    }
}
