import Foundation

/// Finds where a known block is drawn on a terminal screen, so its hover
/// affordance can sit next to it.
///
/// Agent TUIs re-render markdown: they drop the fences, indent, hard-wrap
/// long lines at the pane width and prefix message glyphs. Matching therefore
/// ignores all whitespace and lets one block line span several screen rows.
public struct TerminalCodeBlockScreenLocator: Sendable {
    /// Glyphs agent TUIs draw in front of message or block lines.
    static let decorationPrefixes: [Character] = ["⏺", "●", "•", "│", "┃", "▌", "▎", "╎"]

    public init() {}

    /// The rows (inclusive) where `lines` appear, bottom-most match first,
    /// or `nil` when the block is not on screen in full.
    ///
    /// - Parameters:
    ///   - lines: The block as written (fence body or offered text lines).
    ///   - rows: The screen, one string per grid row.
    public func locate(_ lines: [String], in rows: [String]) -> ClosedRange<Int>? {
        locate(lines, inSquashedScreen: squashedScreen(rows))
    }

    /// The screen in the form ``locate(_:inSquashedScreen:)`` compares
    /// against; compute once when locating several blocks.
    public func squashedScreen(_ rows: [String]) -> [String] {
        rows.map { Self.squashed(Self.strippingDecoration($0)) }
    }

    /// ``locate(_:in:)`` against a screen from ``squashedScreen(_:)``.
    public func locate(_ lines: [String], inSquashedScreen screen: [String]) -> ClosedRange<Int>? {
        let target = lines.map(Self.squashed).filter { !$0.isEmpty }
        guard let first = target.first else { return nil }
        var start = screen.count - 1
        while start >= 0 {
            let row = screen[start]
            if !row.isEmpty, first.hasPrefix(row), let end = match(target, in: screen, from: start) {
                return start...end
            }
            start -= 1
        }
        return nil
    }

    private func match(_ target: [String], in screen: [String], from start: Int) -> Int? {
        var row = start
        for line in target {
            var accumulated = ""
            while accumulated.count < line.count {
                guard row < screen.count else { return nil }
                let piece = screen[row]
                row += 1
                if piece.isEmpty {
                    // Blank rows may separate lines, never split one.
                    if accumulated.isEmpty { continue }
                    return nil
                }
                accumulated += piece
                guard line.hasPrefix(accumulated) else { return nil }
            }
            guard accumulated == line else { return nil }
        }
        return row - 1
    }

    static func squashed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    static func strippingDecoration(_ row: String) -> String {
        let trimmed = row.drop(while: { $0 == " " })
        guard let first = trimmed.first, decorationPrefixes.contains(first) else { return row }
        return String(trimmed.dropFirst())
    }
}

/// What Run may do with a block.
public struct TerminalCodeBlockRunPolicy: Sendable {
    /// Commands longer than this are shown in full before Run proceeds.
    public let reviewCharacterThreshold: Int

    public init(reviewCharacterThreshold: Int = 80) {
        self.reviewCharacterThreshold = reviewCharacterThreshold
    }

    /// Whether Run must show the whole command and wait for a second click
    /// before pasting it: multi-line or long commands, or any that carry
    /// control characters.
    public func requiresReview(_ text: String) -> Bool {
        let paste = pasteText(text)
        var unsanitized = text.replacingOccurrences(of: "\r\n", with: "\n")
        while unsanitized.hasSuffix("\n") { unsanitized.removeLast() }
        return paste.contains("\n")
            || paste.count > reviewCharacterThreshold
            || paste != unsanitized
    }

    /// Whether `text` may be typed into a shell now.
    ///
    /// Typed text reaches the shell as a paste. A newline in a paste is
    /// Return unless the line editor has bracketed paste (DEC mode 2004) on,
    /// so a multi-line command waits for that mode; a one-line command has
    /// no newline to run it.
    public func mayPaste(_ text: String, bracketedPasteActive: Bool) -> Bool {
        !pasteText(text).contains("\n") || bracketedPasteActive
    }

    /// The text Run pastes: control characters other than newline and tab
    /// removed (no escape sequences, no bracketed-paste terminator), CRLF
    /// folded, and no trailing newline, so pasting never presses Enter.
    public func pasteText(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let scalars = normalized.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            if (0x80...0x9F).contains(scalar.value) { return false }
            return true
        }
        var result = String(String.UnicodeScalarView(scalars))
        while result.hasSuffix("\n") { result.removeLast() }
        return result
    }
}
