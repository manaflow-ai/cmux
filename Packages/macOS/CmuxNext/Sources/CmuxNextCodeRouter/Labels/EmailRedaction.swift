import Foundation

/// Email redaction shared by detection, the CodeRouter client boundary and
/// the socket outputs. Deliberately broad: any run of non-space characters
/// (a quoted part counts as one run, spaces included) that holds an `@`,
/// a full-width `＠` or a URL-encoded `%40` is treated
/// as an email, whatever its script, quoting or domain form
/// (`jörg@bücher.de`, `"john doe"@example.com`, `user@[10.0.0.1]`). Such a
/// run becomes `j…@b…`: at most one character on each side, and every `@`
/// in the output follows `…`, so the output never matches an email.
public enum EmailRedaction {
    /// `@`, full-width `＠`, small `﹫`, and the URL-encoded forms. Found
    /// by literal (scalar-level) search, so an `@` followed by a combining
    /// mark still counts.
    static let markers = ["@", "\u{FF20}", "\u{FE6B}", "%40", "%2540"]

    public static func containsEmail(_ text: String) -> Bool {
        markers.contains { text.range(of: $0, options: .literal) != nil }
    }

    /// A non-JSON body with HTML or JSON escapes of `@` decoded first, so
    /// `someone&#64;example.com` is redacted like `someone@example.com`.
    public static func redactEmails(inBody text: String) -> String {
        var decoded = text
        for escape in ["\\u0040", "&#64;", "&#x40;", "&#X40;", "&commat;"] {
            decoded = decoded.replacingOccurrences(of: escape, with: "@", options: .caseInsensitive)
        }
        return redactEmails(in: decoded)
    }

    /// Every email-like run inside `text` shortened; the rest unchanged.
    public static func redactEmails(in text: String) -> String {
        guard containsEmail(text) else { return text }
        var output = "", run = "", quoted = false
        func flush() {
            output += containsEmail(run) ? shorten(run: run) : run
            run = ""
        }
        for character in text {
            // A quoted local part (`"john doe"@example.com`) is one run.
            if character == "\"" { quoted.toggle() }
            if character.isWhitespace, !quoted {
                flush()
                output.append(character)
            } else {
                run.append(character)
            }
        }
        flush()
        return output
    }

    /// An identity as a display: an email becomes `s…@e…` (the whole
    /// value, spaces included, counts as one), anything else its first
    /// character and `…`. Never the full local part or domain.
    public static func redact(identity: String) -> String {
        let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if containsEmail(trimmed) { return shorten(run: trimmed, keepingPunctuation: false) }
        return trimmed.first.map { "\($0)…" } ?? "…"
    }

    private static let openers = Set("([{<")
    private static let closers = Set(")]}>'.,;:!?")

    /// `(someone@example.com).` -> `(s…@e…).`; quotes are dropped, so the
    /// output toggles no quoted run and redacting again changes nothing.
    static func shorten(run: String, keepingPunctuation: Bool = true) -> String {
        var core = Substring(run)
        let prefix = String(core.prefix { openers.contains($0) })
        core = core.dropFirst(prefix.count)
        var suffix = ""
        while let last = core.last, closers.contains(last) {
            suffix = String(last) + suffix
            core = core.dropLast()
        }
        let marker = markers.compactMap { core.range(of: $0, options: .literal) }.min { $0.lowerBound < $1.lowerBound }
        let local = marker.map { core[..<$0.lowerBound] } ?? core
        let domain = marker.map { core[$0.upperBound...] } ?? ""
        let short = initial(local) + "…@" + initial(domain) + "…"
        return keepingPunctuation ? prefix + short + suffix : short
    }

    /// The first letter or digit, else nothing.
    private static func initial(_ part: Substring) -> String {
        part.first { $0.isLetter || $0.isNumber }.map(String.init) ?? ""
    }
}
