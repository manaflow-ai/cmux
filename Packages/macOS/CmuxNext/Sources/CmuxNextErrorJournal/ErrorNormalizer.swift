import Foundation

/// Turns a message into its template: the stable text that names the same problem
/// whatever ids, numbers, paths or quoted values one occurrence carried.
///
/// ```swift
/// ErrorNormalizer().template("took 512 ms for /Users/a/x.json") // "took <n> ms for <path>"
/// ```
///
/// Every rule runs in time linear in the message (p10-stability-191), and a message is read up to
/// ``maxInputUTF16`` units: the template keeps `maxBytes` of it.
public struct ErrorNormalizer {
    /// The most UTF-16 units of a message ``template(_:)`` reads.
    public static let maxInputUTF16 = 16_384

    private let rules: [(NSRegularExpression, String)]
    private let maxBytes: Int

    /// Makes a normalizer.
    /// - Parameter maxBytes: Most UTF-8 bytes of a template.
    public init(maxBytes: Int = 1024) {
        let patterns: [(String, String)] = [
            (#"\x1b\[[0-9;]*[A-Za-z]"#, ""),
            (#"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?"#, "<time>"),
            (#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, "<uuid>"),
            (#"(?i)\b0x[0-9a-f]+\b"#, "<hex>"),
            // A scheme starts where its run of letters starts: every later letter of the run reaches
            // the same `://` or fails the same way, and trying each was quadratic in a long word.
            (#"(?<![a-z])[a-z]++://[^\s"'<>)]+"#, "<url>"),
            (#"(?:~|/(?:Users|private|tmp|var|Applications|Library|opt|System|Volumes))(?:/[^\s"':,()\[\]]+)+"#, "<path>"),
            (#""[^"\n]{0,200}""#, "\"<str>\""),
            (#"'[^'\n]{0,200}'"#, "'<str>'"),
            (#"\b[A-Za-z]+_[0-9a-f]{6,}\b"#, "<id>"),
            // A hex word with a digit and a letter. Two lookaheads, one scan each: the former
            // `[0-9a-f]*\d[0-9a-f]*[a-f][0-9a-f]*` backtracked through every split of a long word.
            (#"\b(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]+\b"#, "<id>"),
            (#"\d+(?:\.\d+)?"#, "<n>"),
            (#"\s+"#, " "),
        ]
        // Constant patterns (ErrorJournalTests); one that failed to compile is skipped, not a crash.
        rules = patterns.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
        }
        self.maxBytes = maxBytes
    }

    /// Returns the template of `message`.
    public func template(_ message: String) -> String {
        var text = message.utf16.count > Self.maxInputUTF16 ? message.utf16Prefix(Self.maxInputUTF16) : message
        for (rule, replacement) in rules {
            text = rule.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                 withTemplate: replacement)
        }
        return text.trimmingCharacters(in: .whitespaces).utf8Prefix(maxBytes)
    }
}

extension String {
    /// The longest prefix of at most `units` UTF-16 units that ends on a scalar boundary.
    func utf16Prefix(_ units: Int) -> String {
        var end = utf16.index(utf16.startIndex, offsetBy: units, limitedBy: utf16.endIndex) ?? utf16.endIndex
        while end > utf16.startIndex, String.Index(end, within: unicodeScalars) == nil { end = utf16.index(before: end) }
        return String(unicodeScalars[..<end])
    }

    /// The longest prefix of at most `bytes` UTF-8 bytes that ends on a character boundary.
    func utf8Prefix(_ bytes: Int) -> String {
        guard utf8.count > bytes else { return self }
        var end = utf8.index(utf8.startIndex, offsetBy: bytes)
        while end > utf8.startIndex, String.Index(end, within: self) == nil { end = utf8.index(before: end) }
        return String(self[..<(String.Index(end, within: self) ?? startIndex)]) + "…"
    }
}
