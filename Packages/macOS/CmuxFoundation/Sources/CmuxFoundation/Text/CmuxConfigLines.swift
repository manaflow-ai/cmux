import Foundation

/// Splits and rejoins line-oriented config bodies for cmux's config editors (the
/// Ghostty config, Codex's `config.toml`), reading LF, CRLF, and lone-CR endings
/// alike and writing back the style the file arrived in.
///
/// Swift treats `"\r\n"` as a single `Character`, so `contents.hasSuffix("\n")`
/// is `false` for CRLF-terminated text even though `components(separatedBy:)`,
/// which works on UTF-16 code units, still splits on the `"\n"` inside it. Code
/// that pairs the two keeps the trailing empty element the check was meant to
/// drop — growing one blank line per rewrite — and the `"\r"` left on every line
/// defeats the exact marker comparisons these editors do afterwards.
///
/// `CharacterSet.newlines` is not a substitute:
/// `components(separatedBy: .newlines)` treats `"\r\n"` as two separators and
/// yields a spurious empty element between every pair of lines.
public struct CmuxConfigLines: Sendable {
    /// The newline style a config body is written with.
    public enum LineEnding: String, Sendable {
        case lf = "\n"
        case crlf = "\r\n"
    }

    public init() {}

    /// The line ending `contents` uses, judged by its first line break.
    ///
    /// - Parameter contents: A config body, possibly empty.
    /// - Returns: ``LineEnding/crlf`` only when the first break in `contents` is
    ///   a CRLF, so a rewrite never converts an LF file (or one with no break at
    ///   all) to CRLF. A classic-Mac CR-only body reads as ``LineEnding/lf`` and
    ///   is rewritten with LF; ``split(_:)`` still finds its lines. That
    ///   normalization is deliberate: TOML, one of the formats edited through
    ///   this helper, defines a newline as LF or CRLF only, so writing lone CRs
    ///   back would emit a file its own parser rejects.
    public func lineEnding(of contents: String) -> LineEnding {
        // Character comparison sees "\r\n" as one grapheme cluster rather than
        // two, which is what lets one scan tell a CRLF break apart from a bare
        // LF or a lone CR. The styles ``split(_:)`` recognizes are exactly the
        // ones tested here, so the two functions agree on where a line ends.
        guard let firstBreak = contents.first(where: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }) else {
            return .lf
        }
        return firstBreak == "\r\n" ? .crlf : .lf
    }

    /// Splits `contents` into lines, tolerating LF, CRLF, and lone-CR endings.
    ///
    /// - Parameter contents: A config body, possibly empty.
    /// - Returns: The lines without their endings, and without the empty element
    ///   a terminal newline leaves behind, so a body and its CRLF twin split
    ///   identically. Empty content splits into no lines.
    public func split(_ contents: String) -> [String] {
        guard !contents.isEmpty else { return [] }
        // Fold CRLF and lone CR down to LF first: splitting on "\n" alone would
        // leave a "\r" on the end of every line of a CRLF body, and would miss
        // the breaks in a CR-only one entirely.
        // The scan is over scalars on purpose: `contents.contains("\r")` compares
        // Characters, and the "\r" of a CRLF is part of the "\r\n" grapheme
        // cluster, so it would answer false for exactly the bodies at issue.
        let normalized = contents.unicodeScalars.contains("\r")
            ? contents
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            : contents
        var lines = normalized.components(separatedBy: "\n")
        // `components(separatedBy:)` leaves a trailing empty element only when
        // the content ends with the separator, so testing the split result
        // covers a trailing "\n" and a trailing "\r\n" alike — unlike
        // `contents.hasSuffix("\n")`, which is false for the latter.
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// Rejoins `lines` with `lineEnding`, terminating the final line.
    ///
    /// - Parameters:
    ///   - lines: Lines as returned by ``split(_:)``, without line endings.
    ///   - lineEnding: The style to write, normally ``lineEnding(of:)`` of the
    ///     content the lines came from.
    /// - Returns: The rejoined body, or empty content for no lines rather than a
    ///   lone newline, so `joined(split(contents), lineEnding: lineEnding(of: contents))`
    ///   round-trips a config body that ends in a newline.
    public func joined(_ lines: [String], lineEnding: LineEnding = .lf) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: lineEnding.rawValue) + lineEnding.rawValue
    }
}
