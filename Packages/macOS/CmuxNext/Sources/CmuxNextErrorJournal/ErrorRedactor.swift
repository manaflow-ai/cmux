import Foundation

/// Removes secrets from text before it is journaled: auth headers, cookies, bearer and API
/// tokens, JWTs, URL credentials and secret query values, and long opaque blobs.
///
/// Every pass is linear in the text (p10-stability-191): the patterns cap or make possessive
/// each run a backtracking matcher could rescan from many starts, and `key=` / `key:` anchors
/// and query keys are found by scanners, not by regexes. Chromium runs untrusted text through
/// RE2, which is linear by construction (third_party/re2); Foundation has none, so the bound is
/// here. Text past ``maxInputScalars`` (and ``capOverscanScalars``) is not read.
///
/// ```swift
/// ErrorRedactor().redact("Authorization: Bearer abc.def") // "Authorization=<redacted>"
/// ```
public struct ErrorRedactor {
    /// The most Unicode scalars of one text ``redact(_:)`` reads: the journal keeps at most
    /// 1 KiB of a message, and the cap bounds the passes over a huge log line.
    public static let maxInputScalars = 16_384
    /// Scalars past ``maxInputScalars`` ``redact(_:)`` still reads, so a secret the cap splits is
    /// whole when the rules run: longer than the longest fixed-length secret a rule matches.
    static let capOverscanScalars = 256

    private let rules: [(NSRegularExpression, String)]
    /// False when a built-in pattern failed to compile: ``redact(_:)`` then keeps no text at all.
    private let complete: Bool
    private static let sensitiveAssignmentComponents: Set<String> = [
        "auth", "authorization", "cookie", "credential", "credentials", "password", "passwd", "pwd", "secret",
        "token",
    ]
    private static let keyShapeComponents: Set<String> = ["access", "api", "client", "private", "session"]
    private static let exactQueryKeys: Set<String> = [
        "access_token", "refresh_token", "token", "key", "api_key", "apikey", "sig", "signature",
        "code", "auth", "authorization", "password", "passwd", "pwd", "secret",
    ]
    static let sensitiveQueryComponents: Set<String> = [
        "auth", "authorization", "code", "credential", "credentials", "key", "password", "passwd", "pwd",
        "secret", "sig", "signature", "token",
    ]

    /// Makes a redactor with the built-in rules.
    public init() {
        let patterns: [(String, String)] = [
            // URL credentials: scheme://user:password@host. The scheme is capped and possessive, so
            // a long word is not rescanned from each of its letters; $1 keeps the scheme as written.
            (#"([A-Za-z][A-Za-z0-9+.\-]{0,31}+://)[^/?#\s]+@"#, "$1<redacted>@"),
            // Cookie and authorization headers contain structured lists whose
            // later fields are just as sensitive as the first one.
            (#"(?i)\b((?:proxy-)?authorization|(?:set-)?cookie)(\s*[:=]\s*)[^\r\n]+"#, "$1$2<redacted>"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
            // `eyJ-eyJ-…` starts a scan at every `eyJ`: the header ends at the next `-eyJ`, with no
            // length cap (an x5c JWS header runs to kilobytes).
            (#"\beyJ(?:[A-Za-z0-9_]|-(?!eyJ)){6,}+\.[A-Za-z0-9_-]{6,}+\.[A-Za-z0-9_-]{6,}"#, "<jwt>"),
            (#"\b(?:sk|pk|rk|ghp|gho|ghu|ghs|ghr|github_pat|xox[abprs]|AKIA|ASIA)[-_]?[A-Za-z0-9_-]{12,}"#, "<redacted>"),
            // Long opaque runs (keys, hashes, base64 payloads).
            (#"[A-Za-z0-9+/_=-]{48,}"#, "<blob>"),
        ]
        // Constant patterns (ErrorJournalTests). Were one ever to fail to compile, redaction fails
        // closed: the whole text is replaced rather than journaled half-scrubbed, and nothing crashes.
        let compiled = patterns.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
        }
        rules = compiled
        complete = compiled.count == patterns.count
    }

    /// Returns `text` with every secret replaced by a placeholder.
    ///
    /// A longer text is redacted on its first ``maxInputScalars`` plus ``capOverscanScalars``
    /// scalars, and the result is cut at ``maxInputScalars`` scalars and ends with "…".
    public func redact(_ text: String) -> String {
        guard complete else { return "<redacted>" }
        let scalars = text.unicodeScalars
        let readEnd = scalars.index(scalars.startIndex, offsetBy: Self.maxInputScalars + Self.capOverscanScalars,
                                    limitedBy: scalars.endIndex) ?? scalars.endIndex
        let readsAll = readEnd == scalars.endIndex
        var text = readsAll ? text : String(String.UnicodeScalarView(scalars[..<readEnd]))
        for (rule, replacement) in rules {
            text = rule.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                 withTemplate: replacement)
        }
        return Self.capped(redactQueryAssignments(in: redactAssignments(in: text)), readsAll: readsAll)
    }

    /// `redacted` cut hard at ``maxInputScalars`` scalars, then "…"; itself when it read the whole
    /// text and is not longer. When the text was cut before the rules ran, its last
    /// ``capOverscanScalars`` scalars go first: a secret cut short there might match no rule.
    static func capped(_ redacted: String, readsAll: Bool) -> String {
        let scalars = redacted.unicodeScalars
        let kept = readsAll ? scalars[...] : scalars.dropLast(capOverscanScalars)
        guard !readsAll || scalars.count > maxInputScalars else { return redacted }
        return String(String.UnicodeScalarView(kept.prefix(maxInputScalars))) + "…"
    }

    private func redactAssignments(in text: String) -> String {
        let source = text as NSString
        var ranges: [NSRange] = []
        var coveredUntil = 0
        for anchor in Self.assignmentAnchors(in: Array(text.utf16)) {
            guard anchor.key.location >= coveredUntil else { continue }
            let key = source.substring(with: anchor.key)
            guard Self.isSensitiveAssignmentKey(key) else { continue }
            let valueStart = anchor.end
            let valueEnd = Self.assignmentValueEnd(in: source, from: valueStart)
            ranges.append(NSRange(location: valueStart, length: valueEnd - valueStart))
            coveredUntil = valueEnd
        }
        return Self.replacing(ranges, in: source)
    }

    private func redactQueryAssignments(in text: String) -> String {
        let source = text as NSString
        let units = Array(text.utf16)
        let keys = Self.queryKeys(in: units)
        var ranges: [NSRange] = []
        var coveredUntil = 0
        var index = 0
        while index < keys.count {
            // The keys that end at one `=` share its value (``isSensitiveQueryGroup``).
            let valueStart = NSMaxRange(keys[index]) + 1
            var next = index + 1
            while next < keys.count, NSMaxRange(keys[next]) + 1 == valueStart { next += 1 }
            if valueStart >= coveredUntil, Self.isSensitiveQueryGroup(keys[index..<next], units: units, source: source) {
                let valueEnd = Self.queryValueEnd(in: source, from: valueStart)
                ranges.append(NSRange(location: valueStart, length: valueEnd - valueStart))
                coveredUntil = valueEnd
            }
            index = next
        }
        return Self.replacing(ranges, in: source)
    }

    /// `source` with each of `ranges` (in order, not overlapping) replaced by `<redacted>`, built in
    /// one forward pass.
    private static func replacing(_ ranges: [NSRange], in source: NSString) -> String {
        var result = ""
        var copied = 0
        for range in ranges {
            result += source.substring(with: NSRange(location: copied, length: range.location - copied))
            result += "<redacted>"
            copied = NSMaxRange(range)
        }
        return result + source.substring(from: copied)
    }

    static func isSensitiveQueryKey(_ key: String) -> Bool {
        let encoded = key.replacingOccurrences(of: "+", with: " ")
        let decoded = encoded.removingPercentEncoding ?? encoded
        let components = decoded.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let normalized = components.joined(separator: "_")
        return exactQueryKeys.contains(normalized)
            || components.contains(where: sensitiveQueryComponents.contains)
    }

    private static func isSensitiveAssignmentKey(_ key: String) -> Bool {
        let components = normalizedAssignmentKey(key).split(separator: "_").map(String.init)
        if components.contains(where: sensitiveAssignmentComponents.contains) { return true }
        return components.contains("key") && components.contains(where: keyShapeComponents.contains)
    }

    private static func normalizedAssignmentKey(_ key: String) -> String {
        let characters = Array(key)
        var normalized = ""
        for index in characters.indices {
            let character = characters[index]
            guard character.isLetter || character.isNumber else {
                if normalized.last != "_" { normalized.append("_") }
                continue
            }
            let previous = index > characters.startIndex ? characters[characters.index(before: index)] : nil
            let next = index < characters.index(before: characters.endIndex)
                ? characters[characters.index(after: index)] : nil
            if character.isUppercase,
               (previous?.isLowercase == true || previous?.isNumber == true
                   || (previous?.isUppercase == true && next?.isLowercase == true)),
               normalized.last != "_" {
                normalized.append("_")
            }
            normalized.append(contentsOf: character.lowercased())
        }
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func assignmentValueEnd(in source: NSString, from start: Int) -> Int {
        var quoteIndex = start
        while quoteIndex < source.length, source.character(at: quoteIndex) == 92 { quoteIndex += 1 }
        guard quoteIndex < source.length else { return source.length }
        let quote = source.character(at: quoteIndex)
        guard quote == 34 || quote == 39 else {
            var end = start
            while end < source.length, !isUnquotedBoundary(source.character(at: end)) {
                if isHorizontalWhitespace(source.character(at: end)) {
                    // Every space of one run sees the same text after it: decide once, then skip the run.
                    let runEnd = horizontalWhitespaceEnd(in: source, from: end)
                    if hasAssignment(in: source, at: runEnd) { return end }
                    end = runEnd
                    continue
                }
                end += 1
            }
            return end
        }

        let delimiterEscapeDepth = quoteIndex - start
        var index = quoteIndex + 1
        while index < source.length {
            let character = source.character(at: index)
            if character == 10 || character == 13 { return index }
            if character == 92 {
                let runStart = index
                while index < source.length, source.character(at: index) == 92 { index += 1 }
                if index < source.length, source.character(at: index) == quote {
                    if index - runStart == delimiterEscapeDepth { return index + 1 }
                    index += 1
                }
                continue
            }
            if delimiterEscapeDepth == 0, character == quote { return index + 1 }
            index += 1
        }
        return source.length
    }

    private static func isUnquotedBoundary(_ character: unichar) -> Bool {
        character == 10 || character == 13 || character == 38 || character == 44 || character == 59 || character == 125
    }

    private static func horizontalWhitespaceEnd(in source: NSString, from start: Int) -> Int {
        var index = start
        while index < source.length, isHorizontalWhitespace(source.character(at: index)) { index += 1 }
        return index
    }

    /// Whether `key =` / `key:` starts at `start` (the end of a run of spaces).
    private static func hasAssignment(in source: NSString, at start: Int) -> Bool {
        var index = start
        guard index < source.length, isAssignmentKeyStart(source.character(at: index)) else { return false }
        index += 1
        while index < source.length, isAssignmentKeyCharacter(source.character(at: index)) { index += 1 }
        while index < source.length, isHorizontalWhitespace(source.character(at: index)) { index += 1 }
        guard index < source.length else { return false }
        let separator = source.character(at: index)
        return separator == 58 || separator == 61
    }

    private static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 9 || character == 11 || character == 12 || character == 32
    }

    private static func isAssignmentKeyStart(_ character: unichar) -> Bool {
        (character >= 65 && character <= 90) || character == 95 || (character >= 97 && character <= 122)
    }

    private static func isAssignmentKeyCharacter(_ character: unichar) -> Bool {
        isAssignmentKeyStart(character) || (character >= 48 && character <= 57)
            || character == 45 || character == 46 || character == 91 || character == 93
    }

    private static func queryValueEnd(in source: NSString, from start: Int) -> Int {
        var end = start
        while end < source.length, !isQueryValueBoundary(source.character(at: end)) {
            if isHorizontalWhitespace(source.character(at: end)) {
                let runEnd = horizontalWhitespaceEnd(in: source, from: end)
                if hasAssignment(in: source, at: runEnd) { return end }
                end = runEnd
                continue
            }
            end += 1
        }
        return end
    }

    private static func isQueryValueBoundary(_ character: unichar) -> Bool {
        character == 10 || character == 13 || character == 35 || character == 38 || character == 59 || character == 125
    }
}
