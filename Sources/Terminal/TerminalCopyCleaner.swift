import Foundation

enum TerminalCopyCleaner {
    static func cleanedSelectionText(for text: String) -> String? {
        cleanedSelectionTextForCopy(text)
    }

    /// Overall selection-level safety gate: returns true when the selection
    /// looks like code, structured text, logs, diffs, or command output.
    /// This prevents smart line-merging from damaging structured content.
    private static func selectionIsStructuredOrCode(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let nonEmptyLines = rawLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmptyLines.count >= 2 else { return false }
        if selectionLooksLikeSingleSoftWrappedPath(nonEmptyLines) {
            return false
        }

        var structuredScore = 0
        var inFence = false
        var fenceLines = 0
        var tableLines = 0

        for line in nonEmptyLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inFence.toggle()
                structuredScore += 2
                continue
            }

            if inFence {
                fenceLines += 1
                structuredScore += 2
                continue
            }

            // Stack trace patterns (e.g., "  at com.Example.method(File.swift:42)")
            if matchesStackTracePattern(trimmed) { structuredScore += 2; continue }
            // Diff hunks
            if startsWithDiffMarker(trimmed) { structuredScore += 2; continue }
            // Markdown or ASCII table rows
            if trimmed.hasPrefix("|") { tableLines += 1; structuredScore += 1; continue }
            // JSON/YAML key-value lines
            if matchesKeyValuePattern(trimmed) { structuredScore += 1; continue }
            // Log level / timestamp patterns
            if matchesLogPattern(trimmed) { structuredScore += 2; continue }
            // Command/shell/REPL prompts
            if startsWithPromptMarker(trimmed) { structuredScore += 1; continue }
            // Path-like lines
            if startsWithPathPattern(trimmed) { structuredScore += 1; continue }

            // Indented lines that contain code symbols
            if line.first?.isWhitespace == true && containsCodeSymbols(trimmed) {
                structuredScore += 1
                continue
            }

            // Lines dominated by punctuation / brackets (JSON, code)
            if hasHighSymbolDensity(trimmed) { structuredScore += 1; continue }
        }

        // If a significant portion of the selection is fenced code
        if fenceLines >= 3 && Double(fenceLines) / Double(nonEmptyLines.count) > 0.4 {
            return true
        }

        // If table rows dominate the selection
        if tableLines >= 2 && Double(tableLines) / Double(nonEmptyLines.count) > 0.3 {
            return true
        }

        let totalLines = nonEmptyLines.count
        let ratio = Double(structuredScore) / Double(totalLines * 2) // max score per line is 2
        return ratio > 0.35
    }

    private static func cleanedSelectionTextForCopy(_ text: String) -> String? {
        // Selection-level safety gate: bail out to raw for code/structured text
        guard !selectionIsStructuredOrCode(text) else { return nil }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }

        var mergedLines: [String] = []
        mergedLines.reserveCapacity(lines.count)
        var inFencedBlock = false
        var inTable = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Track fenced code block state
            if trimmed.hasPrefix("```") {
                inFencedBlock.toggle()
                mergedLines.append(line)
                continue
            }

            // Inside a fenced code block — never merge
            if inFencedBlock {
                mergedLines.append(line)
                continue
            }

            // Track table state
            if trimmed.hasPrefix("|") {
                // Table separator row: |---| or |:---| etc.
                if trimmed.range(of: #"^\|[\s\-:]+\|"#, options: .regularExpression) != nil {
                    inTable = true
                }
                if inTable {
                    mergedLines.append(line)
                    continue
                }
                // First table row; enter table mode
                if trimmed.range(of: #"^\|\s*[^|]+\s*\|"#, options: .regularExpression) != nil {
                    inTable = true
                    mergedLines.append(line)
                    continue
                }
            }
            if inTable && trimmed.isEmpty {
                inTable = false
                mergedLines.append(line)
                continue
            }
            if inTable {
                mergedLines.append(line)
                continue
            }

            // Indented code / logs / prompts / stack traces: don't merge
            if line.first?.isWhitespace == true && !trimmed.isEmpty {
                if containsCodeSymbols(trimmed) || matchesLogPattern(trimmed) ||
                   matchesStackTracePattern(trimmed) || startsWithDiffMarker(trimmed) ||
                   matchesKeyValuePattern(trimmed) || startsWithPromptMarker(trimmed) {
                    mergedLines.append(line)
                    continue
                }
            }

            // Try merge
            if let previous = mergedLines.last,
               shouldMergeSoftWrappedLine(previous: previous, next: line) {
                mergedLines[mergedLines.count - 1] = joinSoftWrappedLines(previous: previous, next: line)
            } else {
                mergedLines.append(line)
            }
        }

        let cleaned = mergedLines.joined(separator: "\n")
        let pathCleaned = cleanPathWrapPadding(in: cleaned)
        let proseCleaned = cleanProseWrapPadding(in: pathCleaned)
        guard !proseCleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return proseCleaned
    }

    private static func shouldMergeSoftWrappedLine(previous: String, next: String) -> Bool {
        let previousTrimmed = previous.trimmingCharacters(in: .whitespaces)
        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
        guard !previousTrimmed.isEmpty, !nextTrimmed.isEmpty else { return false }

        if shouldMergePathContinuation(previous: previousTrimmed, next: nextTrimmed) {
            return true
        }

        // Next line starts with whitespace = intentional indentation, don't merge.
        // Path continuations are handled above with a trimmed next line.
        guard next.first?.isWhitespace != true else { return false }

        // Neither line should start a structured block
        guard !startsNewStructuredBlock(previousTrimmed) else { return false }
        guard !startsNewStructuredBlock(nextTrimmed) else { return false }

        // Hard boundary: previous line ends a sentence/statement
        guard !endsWithHardBoundary(previousTrimmed) else { return false }

        // Log, stack trace, diff, prompt, key-value: don't merge either side
        if matchesLogPattern(previousTrimmed) || matchesLogPattern(nextTrimmed) { return false }
        if matchesStackTracePattern(previousTrimmed) || matchesStackTracePattern(nextTrimmed) { return false }
        if startsWithDiffMarker(previousTrimmed) || startsWithDiffMarker(nextTrimmed) { return false }
        if startsWithPromptMarker(previousTrimmed) || startsWithPromptMarker(nextTrimmed) { return false }
        if matchesKeyValuePattern(previousTrimmed) || matchesKeyValuePattern(nextTrimmed) { return false }

        let nextStartsLowercaseASCII = nextTrimmed.unicodeScalars.first.map(isLowercaseASCII) ?? false
        let nextStartsCJK = nextTrimmed.unicodeScalars.first.map(isCJKScalar) ?? false
        let previousContainsCJK = containsCJK(previousTrimmed)
        let nextContainsCJK = containsCJK(nextTrimmed)

        // CJK prose: merge if both contain CJK and previous looks terminal-wrapped
        if nextStartsCJK || (previousContainsCJK && nextContainsCJK) {
            return previousLineLooksTerminalWrapped(previousTrimmed)
        }

        // English prose: only merge if next starts lowercase AND previous looks wrapped
        guard nextStartsLowercaseASCII else { return false }
        return previousLineLooksTerminalWrapped(previousTrimmed)
    }

    /// Returns true if a line looks like it was wrapped by a terminal at ~width boundary,
    /// rather than being an intentional short line (prompt output, code, log, etc.).
    /// Requires the line to be at least 40 chars OR end mid-word for CJK.
    private static func previousLineLooksTerminalWrapped(_ line: String) -> Bool {
        let count = line.count
        // Short lines (under 20 chars) are almost never soft wraps; they're intentional newlines
        if count < 20 { return false }
        // Full-ish lines (>= 40 chars) that don't end in sentence-ending punctuation are likely wraps
        if count >= 40 {
            let last = line.unicodeScalars.last
            let sentenceEnders: Set<UInt32> = [
                0x002E, // .
                0x0021, // !
                0x003F, // ?
                0x3002, // 。
                0xFF01, // ！
                0xFF1F, // ？
                0x003A, // :
                0xFF1A, // ：
                0x003B, // ;
                0xFF1B, // ；
            ]
            if let last = last {
                // Comma alone at <60 chars often means the line isn't fully wrapped yet
                if last.value == 0x002C || last.value == 0xFF0C { // , or ，
                    return count >= 60
                }
                if sentenceEnders.contains(last.value) {
                    return false
                }
            }
            return true
        }
        // 20-39 chars: only merge for unambiguous continuations (start mid-sentence)
        return false  // 20-39 chars: shouldMergeSoftWrappedLine already handles next-line start features; short lines should not default-merge
    }

    // MARK: - Existing helpers (preserved)
    private static func selectionLooksLikeSingleSoftWrappedPath(_ lines: [String]) -> Bool {
        guard var merged = lines.first?.trimmingCharacters(in: .whitespaces), !merged.isEmpty else {
            return false
        }

        var mergedAtLeastOneLine = false
        for line in lines.dropFirst() {
            let next = line.trimmingCharacters(in: .whitespaces)
            guard shouldMergePathContinuation(previous: merged, next: next) else {
                return false
            }
            merged = joinSoftWrappedLines(previous: merged, next: next)
            mergedAtLeastOneLine = true
        }

        return mergedAtLeastOneLine
    }

    private static func shouldMergePathContinuation(previous: String, next: String) -> Bool {
        let previousTrimmed = previous.trimmingCharacters(in: .whitespaces)
        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
        guard !previousTrimmed.isEmpty, !nextTrimmed.isEmpty else { return false }
        guard isPathStart(previousTrimmed) || looksLikePathFragment(previousTrimmed) else { return false }
        guard previousPathLineLooksTerminalWrapped(previousTrimmed) else { return false }
        guard !isPathStart(nextTrimmed) else { return false }
        guard !startsWithPromptMarker(nextTrimmed) else { return false }
        guard !startsWithDiffMarker(nextTrimmed) else { return false }
        guard !matchesLogPattern(nextTrimmed) else { return false }
        guard !matchesStackTracePattern(nextTrimmed) else { return false }
        guard !matchesKeyValuePattern(nextTrimmed) else { return false }
        return looksLikePathContinuation(nextTrimmed)
    }

    private static func joinSoftWrappedLines(previous: String, next: String) -> String {
        let previousTrimmed = previous.trimmingCharacters(in: .whitespaces)
        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
        guard !previousTrimmed.isEmpty else { return nextTrimmed }
        guard !nextTrimmed.isEmpty else { return previousTrimmed }

        let separator = joinSeparatorForCopy(previous: previousTrimmed, next: nextTrimmed)
        return previousTrimmed + separator + nextTrimmed
    }

    private static func joinSeparatorForCopy(previous: String, next: String) -> String {
        if shouldMergePathContinuation(previous: previous, next: next) {
            return ""
        }

        let previousEndsCJK = previous.unicodeScalars.last.map(isCJKScalar) ?? false
        let nextStartsCJK = next.unicodeScalars.first.map(isCJKScalar) ?? false
        return (previousEndsCJK || nextStartsCJK) ? "" : " "
    }

    /// Normalizes terminal wrap padding within path segments (same-line, not cross-line).
    /// When Ghostty wraps a long path visually, raw selection may contain 2+ spaces
    /// where the wrap occurred (e.g. "/DerivedData/  cmux-..."). This removes such
    /// padding while preserving single-space path separators for real paths.
    private static func cleanPathWrapPadding(in text: String) -> String {
        guard needsPathWrapPaddingCleaning(text) else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var idx = text.startIndex

        while idx < text.endIndex {
            let char = text[idx]
            if char == "/" {
                result.append("/")
                idx = text.index(after: idx)

                var whitespaceCount = 0
                var scanIdx = idx
                while scanIdx < text.endIndex, text[scanIdx] == " " || text[scanIdx] == "\t" {
                    whitespaceCount += 1
                    scanIdx = text.index(after: scanIdx)
                }

                if whitespaceCount >= 2, scanIdx < text.endIndex,
                   isPathSegmentStartChar(text[scanIdx]) {
                    idx = scanIdx
                    continue
                }

                while idx < scanIdx {
                    result.append(text[idx])
                    idx = text.index(after: idx)
                }
            } else {
                result.append(char)
                idx = text.index(after: idx)

                var whitespaceCount = 0
                var scanIdx = idx
                while scanIdx < text.endIndex, text[scanIdx] == " " || text[scanIdx] == "\t" {
                    whitespaceCount += 1
                    scanIdx = text.index(after: scanIdx)
                }

                if whitespaceCount >= 2,
                   scanIdx < text.endIndex,
                   text[scanIdx] == "/",
                   result.unicodeScalars.last.map(isPathSafeScalar) == true {
                    idx = scanIdx
                }
            }
        }

        return result
    }

    private static func needsPathWrapPaddingCleaning(_ text: String) -> Bool {
        if text.hasPrefix("/") { return true }
        if text.hasPrefix("~/") { return true }
        if text.hasPrefix("./") { return true }
        if text.hasPrefix("../") { return true }
        if text.contains("/  ") { return true }
        if text.contains("  /") { return true }
        return false
    }

    private static func isPathSegmentStartChar(_ char: Character) -> Bool {
        if char.isLetter || char.isNumber { return true }
        switch char {
        case ".", "_", "-": return true
        default: return false
        }
    }

    /// Normalizes same-line padding inserted at terminal soft-wrap points in prose.
    /// CJK-to-CJK joins without a space; Latin/number boundaries collapse to one space.
    private static func cleanProseWrapPadding(in text: String) -> String {
        guard text.contains("  ") || text.contains("\t") else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var idx = text.startIndex

        while idx < text.endIndex {
            let char = text[idx]
            guard char == " " || char == "\t" else {
                result.append(char)
                idx = text.index(after: idx)
                continue
            }

            var whitespaceCount = 0
            var scanIdx = idx
            while scanIdx < text.endIndex, text[scanIdx] == " " || text[scanIdx] == "\t" {
                whitespaceCount += 1
                scanIdx = text.index(after: scanIdx)
            }

            if whitespaceCount >= 2,
               let previous = result.unicodeScalars.last,
               scanIdx < text.endIndex,
               let next = String(text[scanIdx]).unicodeScalars.first,
               shouldCollapseProseWrapPadding(previous: previous, next: next) {
                if shouldInsertSpaceWhenCollapsingWrap(previous: previous, next: next) {
                    result.append(" ")
                }
                idx = scanIdx
                continue
            }

            while idx < scanIdx {
                result.append(text[idx])
                idx = text.index(after: idx)
            }
        }

        return result
    }

    private static func shouldCollapseProseWrapPadding(previous: UnicodeScalar, next: UnicodeScalar) -> Bool {
        if isCJKScalar(previous) || isCJKScalar(next) { return true }
        return isAlphaNumericASCII(previous) && isAlphaNumericASCII(next)
    }

    private static func shouldInsertSpaceWhenCollapsingWrap(previous: UnicodeScalar, next: UnicodeScalar) -> Bool {
        if isCJKScalar(previous) && isCJKScalar(next) { return false }
        return true
    }

    private static func isAlphaNumericASCII(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func startsNewStructuredBlock(_ line: String) -> Bool {
        // Code fence (markdown)
        if line.hasPrefix("```") { return true }

        // Horizontal rule
        if line.range(of: #"^[-*_]{3,}\s*$"#, options: .regularExpression) != nil {
            return true
        }

        let structuredPrefixes = [
            "- ", "* ", "+ ", "$ ", "> ", "%% ",  // bullets, prompt, quote, diff
            "/Users/", "~/", "./", "../",
            "{", "}", "[", "]", "<", "</"
        ]
        if structuredPrefixes.contains(where: { line.hasPrefix($0) }) {
            return true
        }

        // Numbered list or path line with "N. " (e.g., "1. ", "12. ")
        if line.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
            return true
        }

        // Markdown table row
        if line.hasPrefix("|") { return true }

        return false
    }

    private static func endsWithHardBoundary(_ line: String) -> Bool {
        let hardBoundarySuffixes = ["!", "?", "。", "！", "？", ":", "：", ";", "；"]
        return hardBoundarySuffixes.contains(where: { line.hasSuffix($0) })
    }

    // MARK: - New structured-text detection helpers

    /// Detects stack trace lines like "  at com.app.Main.main(Main.java:10)"
    private static func matchesStackTracePattern(_ line: String) -> Bool {
        // Pattern: "at " followed by package.class.method(file:line)
        if line.range(of: #"^\s*at\s+\S+\("#, options: .regularExpression) != nil { return true }
        // "Caused by:" patterns
        if line.hasPrefix("Caused by:") { return true }
        // "... N more" frame count
        if line.range(of: #"^\s*\.\.\.\s*\d+\s+more\s*$"#, options: .regularExpression) != nil { return true }
        // File:line patterns like (File.swift:42) or (file.ts:100)
        if line.range(of: #"\([\w./_-]+\.(swift|java|py|ts|js|rs|go|kt|cpp|c|h|m|mm):\d+\)"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Detects diff/patch markers: +++, ---, @@ hunk headers
    private static func startsWithDiffMarker(_ line: String) -> Bool {
        if line.hasPrefix("+++ ") || line.hasPrefix("--- ") { return true }
        if line.hasPrefix("@@") && line.contains("@@") { return true }
        if line.hasPrefix("diff ") { return true }
        if line.hasPrefix("index ") { return true }
        return false
    }

    /// Detects log patterns like "[ERROR]", "[WARN]", "[2024-01-01"
    private static func matchesLogPattern(_ line: String) -> Bool {
        if line.range(of: #"^\[(INFO|WARN|ERROR|DEBUG|TRACE|FATAL|NOTICE|CRITICAL)\s*\]"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        // Timestamp-prefixed log lines
        if line.range(of: #"^\d{2,4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}"#, options: .regularExpression) != nil { return true }
        // Short timestamp like "10:42:33.123"
        if line.range(of: #"^\d{2}:\d{2}:\d{2}\."#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Detects key-value or JSON/YAML property lines
    private static func matchesKeyValuePattern(_ line: String) -> Bool {
        // JSON key: "key": value
        if line.range(of: #"^\s*".*"\s*:"#, options: .regularExpression) != nil { return true }
        // YAML key: value (colon not preceded by https/ftp)
        if line.range(of: #"^\s*[A-Za-z_][\w.]*\s*:"#, options: .regularExpression) != nil {
            if line.contains("://") || line.contains("ftp:") { return false }
            return true
        }
        // INI/config: key=value
        if line.range(of: #"^\s*[A-Za-z_][\w.]*\s*="#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Detects command/shell/REPL prompt markers
    private static func startsWithPromptMarker(_ line: String) -> Bool {
        let promptPrefixes = ["$ ", "# ", ">>> ", "... ", "% ", ">> "]
        return promptPrefixes.contains(where: { line.hasPrefix($0) })
    }

    private static func isPathStart(_ line: String) -> Bool {
        if line == "/" { return true }
        if line.hasPrefix("/") {
            return line.dropFirst().first?.isWhitespace != true
        }
        if line.hasPrefix("~/") || line.hasPrefix("./") || line.hasPrefix("../") {
            return true
        }
        if line.hasPrefix("\\") {
            return line.dropFirst(2).first?.isWhitespace != true
        }
        if line.range(of: #"^[A-Za-z]:(\\|/)"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func looksLikePathFragment(_ line: String) -> Bool {
        guard !line.isEmpty, !line.contains(where: \.isWhitespace) else { return false }
        guard line.contains("/") || line.hasSuffix("/") else { return false }
        return line.unicodeScalars.allSatisfy(isPathSafeScalar)
    }

    private static func looksLikePathContinuation(_ line: String) -> Bool {
        // Guards: non-empty, no whitespace, all scalars path-safe
        guard !line.isEmpty, !line.contains(where: \.isWhitespace) else { return false }
        guard line.unicodeScalars.allSatisfy(isPathSafeScalar) else { return false }

        let count = line.count

        // Slash or backslash -> strong path signal
        if line.contains("/") || line.contains("\\") { return true }

        // Path punctuation / signal characters -> strong signal
        let pathSignals: Set<Character> = [".", "~", "_", "-", "@", "%", "+", "=", ":"]
        if line.contains(where: { pathSignals.contains($0) }) { return true }

        // Any digit + length >= 2 -> likely versioned/numbered path segment
        if line.contains(where: { $0.isNumber }) && count >= 2 { return true }

        // Longer plausible path tokens: must be >= 8 chars and not all letters
        // (all-letter tokens like "Something" without path signal are too risky)
        if count >= 8 && !line.allSatisfy({ $0.isLetter }) { return true }

        // Everything else (short all-letter words like "to", "be", "in", "of"): false
        return false
    }

    private static func previousPathLineLooksTerminalWrapped(_ line: String) -> Bool {
        if previousLineLooksTerminalWrapped(line) {
            return true
        }
        return line.count >= 16 && looksLikePathFragment(line)
    }

    private static func isPathSafeScalar(_ scalar: UnicodeScalar) -> Bool {
        let pathSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._@%+=:/-\\~")
        return pathSafe.contains(scalar)
    }

    /// Detects file paths at line start
    private static func startsWithPathPattern(_ line: String) -> Bool {
        isPathStart(line)
    }

    /// Returns true if the line contains code-like symbols (parens, braces, semicolons, operators)
    private static func containsCodeSymbols(_ line: String) -> Bool {
        let codeChars = CharacterSet(charactersIn: "(){}[]=;:<>")
        let count = line.unicodeScalars.filter { codeChars.contains($0) }.count
        return count >= 3
    }

    /// Returns true if the line has high density of punctuation/symbols (JSON, code, etc.)
    private static func hasHighSymbolDensity(_ line: String) -> Bool {
        guard line.count > 8 else { return false }
        let symbols = CharacterSet(charactersIn: "{}[]()\"':;,.<>=!@#$%^&*+-/\\|")
        let symbolCount = line.unicodeScalars.filter { symbols.contains($0) }.count
        return Double(symbolCount) / Double(line.count) > 0.25
    }

    // MARK: - Character classification helpers (preserved)

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJKScalar)
    }

    private static func isLowercaseASCII(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 97 && scalar.value <= 122
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x2CEB0...0x2EBEF,
             0x3040...0x309F,
             0x30A0...0x30FF,
             0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }


}
