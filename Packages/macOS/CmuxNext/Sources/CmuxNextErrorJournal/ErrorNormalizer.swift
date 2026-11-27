import Foundation

/// Turns a message into its template: the stable text that names the same problem
/// whatever ids, numbers, paths or quoted values one occurrence carried.
///
/// ```swift
/// ErrorNormalizer().template("took 512 ms for /Users/a/x.json") // "took <n> ms for <path>"
/// ```
public struct ErrorNormalizer {
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
            (#"[a-z]+://[^\s"'<>)]+"#, "<url>"),
            (#"(?:~|/(?:Users|private|tmp|var|Applications|Library|opt|System|Volumes))(?:/[^\s"':,()\[\]]+)+"#, "<path>"),
            (#""[^"\n]{0,200}""#, "\"<str>\""),
            (#"'[^'\n]{0,200}'"#, "'<str>'"),
            (#"\b[A-Za-z]+_[0-9a-f]{6,}\b"#, "<id>"),
            (#"\b[0-9a-f]*\d[0-9a-f]*[a-f][0-9a-f]*\b|\b[0-9a-f]*[a-f][0-9a-f]*\d[0-9a-f]*\b"#, "<id>"),
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
        var text = message
        for (rule, replacement) in rules {
            text = rule.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                 withTemplate: replacement)
        }
        return text.trimmingCharacters(in: .whitespaces).utf8Prefix(maxBytes)
    }
}

extension String {
    /// The longest prefix of at most `bytes` UTF-8 bytes that ends on a character boundary.
    func utf8Prefix(_ bytes: Int) -> String {
        guard utf8.count > bytes else { return self }
        var end = utf8.index(utf8.startIndex, offsetBy: bytes)
        while end > utf8.startIndex, String.Index(end, within: self) == nil { end = utf8.index(before: end) }
        return String(self[..<(String.Index(end, within: self) ?? startIndex)]) + "…"
    }
}
