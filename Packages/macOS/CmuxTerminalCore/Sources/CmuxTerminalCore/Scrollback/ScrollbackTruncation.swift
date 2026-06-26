/// Character and line limits applied to captured terminal scrollback before it
/// is persisted or replayed, together with the ANSI-safe truncation that
/// enforces the character cap without slicing through a partial CSI escape
/// sequence.
///
/// An instance carries the limits it enforces; the truncation reads the
/// instance's own `maxCharacters` so callers can configure the bound (tests
/// inject a smaller value) while the default instance reproduces the legacy
/// persistence limits exactly.
public struct ScrollbackTruncation: Sendable, Equatable {
    /// Maximum number of scrollback characters persisted per terminal.
    /// Truncation keeps the trailing `maxCharacters` characters (the most recent
    /// output).
    public let maxCharacters: Int

    /// Maximum number of scrollback lines captured per terminal at snapshot time.
    public let maxLines: Int

    /// Creates a truncation policy. The defaults reproduce the legacy
    /// `SessionPersistencePolicy` scrollback limits.
    public init(maxCharacters: Int = 400_000, maxLines: Int = 4000) {
        self.maxCharacters = maxCharacters
        self.maxLines = maxLines
    }

    /// Truncates `text` to the trailing `maxCharacters` characters, advancing the
    /// truncation boundary past any partial leading ANSI CSI escape sequence.
    /// Returns `nil` for `nil`/empty input and the original text when it already
    /// fits within the limit.
    public func truncated(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= maxCharacters {
            return text
        }
        let initialStart = text.index(text.endIndex, offsetBy: -maxCharacters)
        let safeStart = Self.ansiSafeTruncationStart(in: text, initialStart: initialStart)
        return String(text[safeStart...])
    }

    /// If truncation starts in the middle of an ANSI CSI escape sequence, advance
    /// to the first printable character after that sequence to avoid replaying
    /// malformed control bytes.
    private static func ansiSafeTruncationStart(in text: String, initialStart: String.Index) -> String.Index {
        guard initialStart > text.startIndex else { return initialStart }
        let escape = "\u{001B}"

        guard let lastEscape = text[..<initialStart].lastIndex(of: Character(escape)) else {
            return initialStart
        }
        let csiMarker = text.index(after: lastEscape)
        guard csiMarker < text.endIndex, text[csiMarker] == "[" else {
            return initialStart
        }

        // If a final CSI byte exists before the truncation boundary, we are not
        // inside a partial sequence.
        if csiFinalByteIndex(in: text, from: csiMarker, upperBound: initialStart) != nil {
            return initialStart
        }

        // We are inside a CSI sequence. Skip to the first character after the
        // sequence terminator if it exists.
        guard let final = csiFinalByteIndex(in: text, from: csiMarker, upperBound: text.endIndex) else {
            return initialStart
        }
        let next = text.index(after: final)
        return next < text.endIndex ? next : text.endIndex
    }

    private static func csiFinalByteIndex(
        in text: String,
        from csiMarker: String.Index,
        upperBound: String.Index
    ) -> String.Index? {
        var index = text.index(after: csiMarker)
        while index < upperBound {
            guard let scalar = text[index].unicodeScalars.first?.value else {
                index = text.index(after: index)
                continue
            }
            if scalar >= 0x40, scalar <= 0x7E {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }
}
