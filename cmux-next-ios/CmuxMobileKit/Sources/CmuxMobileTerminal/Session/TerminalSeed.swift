import Foundation

/// The page as last seen on this phone, kept as rows of text and fed into a fresh Ghostty
/// surface before its session starts: a terminal restored after iOS ended the app, or a tab back
/// from the warm set, is then a live surface at once (it scrolls, takes taps and keys, which wait
/// for the attach), not a still picture over a blank one. The Mac's replay, which starts with a
/// full reset, replaces it on attach.
///
/// Leo, 2026-11-24, back from another app: "The like multi-second long reattach where like the
/// entire thing is somehow grayed out and I can't interact with anything at all."
public enum TerminalSeed {
    /// At most this many rows are kept (the newest).
    public static let maxRows = 2_000
    /// At most this many UTF-8 bytes are kept (the newest whole rows).
    public static let maxBytes = 256 * 1024

    /// The rows worth keeping from a surface's screen text (`TerminalSurfaceView.screenText`) or
    /// the Mac's (`read-screen`): the newest rows within the bounds, with no blank rows at the
    /// end. Nil when nothing but blank rows is left.
    public static func rows(fromScreenText text: String) -> String? {
        var lines = Self.rowLines(of: text)
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        lines = Array(lines.suffix(maxRows))
        var bytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        var first = 0
        while bytes > maxBytes, first < lines.count - 1 {
            bytes -= lines[first].utf8.count + 1
            first += 1
        }
        while first < lines.count - 1, lines[first].allSatisfy(\.isWhitespace) { first += 1 }
        return lines[first...].joined(separator: "\n")
    }

    /// The bytes a fresh surface is fed for `rows`: one row per line, with every control
    /// character but a tab removed, so a kept page only ever prints text (it never runs an
    /// escape sequence, never sets a mode or a title).
    public static func bytes(rows: String) -> Data {
        var out = String.UnicodeScalarView()
        var firstLine = true
        for line in Self.rowLines(of: rows) {
            if !firstLine { out.append(contentsOf: "\r\n".unicodeScalars) }
            firstLine = false
            for scalar in line.unicodeScalars where printable(scalar) { out.append(scalar) }
        }
        return Data(String(out).utf8)
    }

    /// `text`'s rows, split at "\n" and "\r\n". Swift reads "\r\n" as one Character, so a
    /// split on "\n" alone keeps a "\r\n" row pair as one row.
    private static func rowLines(of text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
    }

    private static func printable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09: true
        case 0x00..<0x20, 0x7F..<0xA0: false
        default: true
        }
    }
}
