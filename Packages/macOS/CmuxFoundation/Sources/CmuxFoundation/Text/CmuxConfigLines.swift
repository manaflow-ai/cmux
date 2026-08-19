import Foundation

/// Splits and rejoins line-oriented config bodies for cmux's config editors (the
/// Ghostty config, Codex's `config.toml`), tolerating LF and CRLF alike and
/// keeping the ending style the file arrived in.
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
    ///   all) to CRLF.
    public func lineEnding(of contents: String) -> LineEnding {
        // Character comparison sees "\r\n" as one grapheme cluster, so
        // `firstIndex(of: "\n")` finds only bare LFs and `firstIndex(of: "\r\n")`
        // only CRLFs; the earlier of the two is the first line break.
        guard let crlfIndex = contents.firstIndex(of: "\r\n") else { return .lf }
        guard let lfIndex = contents.firstIndex(of: "\n") else { return .crlf }
        return crlfIndex < lfIndex ? .crlf : .lf
    }

    /// Splits `contents` into lines, tolerating LF and CRLF endings alike.
    ///
    /// - Parameter contents: A config body, possibly empty.
    /// - Returns: The lines without their trailing `"\r"`, and without the empty
    ///   element a terminal newline leaves behind, so a body and its CRLF twin
    ///   split identically. Empty content splits into no lines.
    public func split(_ contents: String) -> [String] {
        guard !contents.isEmpty else { return [] }
        var lines = contents.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        // `components(separatedBy:)` leaves a trailing empty element only when
        // `contents` ends with the separator, so testing the split result covers
        // a trailing "\n" and a trailing "\r\n" alike — unlike
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
