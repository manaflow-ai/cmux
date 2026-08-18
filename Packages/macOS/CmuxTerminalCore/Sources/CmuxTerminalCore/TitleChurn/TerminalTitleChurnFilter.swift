/// Command-line spinners animate one glyph next to a stable label. Removing
/// that standalone animation token makes successive frames equal while
/// preserving ordinary titles byte-for-byte.
///
/// The token is removed wherever it sits, not only in leading position, because
/// agents brand their titles: OMP writes `π ⠋ label`, so a leading-only rule
/// leaves its frames churning. A glyph is only removed when whitespace or a
/// string edge bounds it on both sides, and a title containing a run of two or
/// more spinner glyphs is treated as text and returned untouched, which is what
/// keeps Braille words such as `⠋ ⠑⠇⠇⠕` intact.
/// Automatic title bounds and control admission run before spinner detection.
public struct TerminalTitleChurnFilter: Sendable {
    /// Creates a stateless terminal-title normalizer.
    public init() {}

    /// Returns a bounded stable title, or `nil` for unsafe controls or spinner-only frames.
    ///
    /// - Parameter rawTitle: The title received from the terminal runtime.
    /// - Returns: The unchanged ordinary title, its spinner-free label, or `nil`
    ///   when no label remains after normalization.
    public func stableTitle(for rawTitle: String) -> String? {
        guard let boundedTitle = AutomaticTerminalTitle(rawTitle)?.value else { return nil }
        let characters = Array(boundedTitle)
        guard !characters.isEmpty else { return boundedTitle }
        guard !containsGlyphRun(characters) else { return boundedTitle }

        var kept: [Character] = []
        var removedFrame = false
        for (index, character) in characters.enumerated() {
            if isKnownSpinnerFrame(character), isStandaloneToken(at: index, in: characters) {
                removedFrame = true
                continue
            }
            kept.append(character)
        }
        guard removedFrame else { return boundedTitle }

        let label = String(kept)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return label.isEmpty ? nil : label
    }

    /// True when whitespace or a string edge bounds the glyph on both sides, so
    /// it stands alone rather than belonging to a surrounding word.
    private func isStandaloneToken(at index: Int, in characters: [Character]) -> Bool {
        let precedingIsBoundary = index == 0 || characters[index - 1].isWhitespace
        let followingIsBoundary = index == characters.count - 1 || characters[index + 1].isWhitespace
        return precedingIsBoundary && followingIsBoundary
    }

    /// True when two or more spinner-range glyphs sit next to each other, which
    /// reads as text or art rather than a single animation frame.
    private func containsGlyphRun(_ characters: [Character]) -> Bool {
        var runLength = 0
        for character in characters {
            if brailleScalarValue(for: character) != nil || isKnownSpinnerFrame(character) {
                runLength += 1
                if runLength >= 2 { return true }
            } else {
                runLength = 0
            }
        }
        return false
    }

    private func isKnownSpinnerFrame(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        switch value {
        // Braille "dots" frames.
        case 0x280B, 0x2819, 0x2839, 0x2838, 0x283C,
             0x2834, 0x2826, 0x2827, 0x2807, 0x280F:
            return true
        // Asterisk frames. Claude Code animates these, so on an agent-heavy
        // window they are the frames that actually churn.
        case 0x2731...0x273D:
            return true
        // Half-filled and quadrant circle frames.
        case 0x25D0...0x25D3, 0x25F4...0x25F7:
            return true
        default:
            return false
        }
    }
}
