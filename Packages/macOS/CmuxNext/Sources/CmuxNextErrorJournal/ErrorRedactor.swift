import Foundation

/// Removes secrets from text before it is journaled: auth headers, cookies, bearer and API
/// tokens, JWTs, URL credentials and secret query values, and long opaque blobs.
///
/// ```swift
/// ErrorRedactor().redact("Authorization: Bearer abc.def") // "Authorization=<redacted>"
/// ```
public struct ErrorRedactor {
    private let rules: [(NSRegularExpression, String)]
    private let assignmentAnchors: NSRegularExpression?
    private let queryAssignments: NSRegularExpression?
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
    private static let sensitiveQueryComponents: Set<String> = [
        "auth", "authorization", "code", "credential", "credentials", "key", "password", "passwd", "pwd",
        "secret", "sig", "signature", "token",
    ]

    /// Makes a redactor with the built-in rules.
    public init() {
        let patterns: [(String, String)] = [
            // URL credentials: scheme://user:password@host
            (#"([A-Za-z][A-Za-z0-9+.\-]*://)[^/?#\s]+@"#, "$1<redacted>@"),
            // Cookie and authorization headers contain structured lists whose
            // later fields are just as sensitive as the first one.
            (#"(?i)\b((?:proxy-)?authorization|(?:set-)?cookie)(\s*[:=]\s*)[^\r\n]+"#, "$1$2<redacted>"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
            (#"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}"#, "<jwt>"),
            (#"\b(?:sk|pk|rk|ghp|gho|ghu|ghs|ghr|github_pat|xox[abprs]|AKIA|ASIA)[-_]?[A-Za-z0-9_-]{12,}"#, "<redacted>"),
            // Long opaque runs (keys, hashes, base64 payloads).
            (#"[A-Za-z0-9+/_=-]{48,}"#, "<blob>"),
        ]
        // Constant patterns (ErrorJournalTests). Were one ever to fail to compile, redaction fails
        // closed: the whole text is replaced rather than journaled half-scrubbed, and nothing crashes.
        let compiled = patterns.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
        }
        let anchors = try? NSRegularExpression(
            pattern: #"\b([A-Za-z_][A-Za-z0-9_-]*)((?:(?:\\+)?["'])?\s*[:=]\s*)"#
        )
        let query = try? NSRegularExpression(
            pattern: #"(?=(^|[?#&;\s="'=(:,])([^=?&#;\s"']+)=)"#
        )
        rules = compiled
        assignmentAnchors = anchors
        queryAssignments = query
        complete = compiled.count == patterns.count && anchors != nil && query != nil
    }

    /// Returns `text` with every secret replaced by a placeholder.
    public func redact(_ text: String) -> String {
        guard complete, let assignmentAnchors, let queryAssignments else { return "<redacted>" }
        var text = text
        for (rule, replacement) in rules {
            text = rule.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                 withTemplate: replacement)
        }
        return redactQueryAssignments(in: redactAssignments(in: text, anchors: assignmentAnchors), queryAssignments)
    }

    private func redactAssignments(in text: String, anchors assignmentAnchors: NSRegularExpression) -> String {
        let source = text as NSString
        let result = NSMutableString(string: text)
        let matches = assignmentAnchors.matches(in: text, range: NSRange(location: 0, length: source.length))
        var ranges: [NSRange] = []
        var coveredUntil = 0
        for match in matches {
            guard match.range.location >= coveredUntil else { continue }
            let key = source.substring(with: match.range(at: 1))
            guard Self.isSensitiveAssignmentKey(key) else { continue }
            let valueStart = NSMaxRange(match.range)
            let valueEnd = Self.assignmentValueEnd(in: source, from: valueStart)
            ranges.append(NSRange(location: valueStart, length: valueEnd - valueStart))
            coveredUntil = valueEnd
        }
        for range in ranges.reversed() {
            result.replaceCharacters(in: range, with: "<redacted>")
        }
        return result as String
    }

    private func redactQueryAssignments(in text: String, _ queryAssignments: NSRegularExpression) -> String {
        let source = text as NSString
        let result = NSMutableString(string: text)
        let matches = queryAssignments.matches(in: text, range: NSRange(location: 0, length: source.length))
        var ranges: [NSRange] = []
        var coveredUntil = 0
        for match in matches {
            let key = source.substring(with: match.range(at: 2))
            guard Self.isSensitiveQueryKey(key) else { continue }
            let valueStart = NSMaxRange(match.range(at: 2)) + 1
            guard valueStart >= coveredUntil else { continue }
            let valueEnd = Self.queryValueEnd(in: source, from: valueStart)
            ranges.append(NSRange(location: valueStart, length: valueEnd - valueStart))
            coveredUntil = valueEnd
        }
        for range in ranges.reversed() {
            result.replaceCharacters(in: range, with: "<redacted>")
        }
        return result as String
    }

    private static func isSensitiveQueryKey(_ key: String) -> Bool {
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
                if isHorizontalWhitespace(source.character(at: end)), hasAssignmentAfterWhitespace(in: source, from: end) {
                    return end
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

    private static func hasAssignmentAfterWhitespace(in source: NSString, from start: Int) -> Bool {
        var index = start
        while index < source.length, isHorizontalWhitespace(source.character(at: index)) { index += 1 }
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
            if isHorizontalWhitespace(source.character(at: end)), hasAssignmentAfterWhitespace(in: source, from: end) {
                return end
            }
            end += 1
        }
        return end
    }

    private static func isQueryValueBoundary(_ character: unichar) -> Bool {
        character == 10 || character == 13 || character == 35 || character == 38 || character == 59 || character == 125
    }
}
