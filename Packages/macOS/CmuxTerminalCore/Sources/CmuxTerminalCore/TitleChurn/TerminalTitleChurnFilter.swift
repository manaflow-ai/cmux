/// Normalizes animated terminal titles before title-update deduplication.
///
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
public struct TerminalTitleChurnFilter: Sendable {
    /// Creates a stateless terminal-title normalizer.
    public init() {}

    /// Returns a stable title, or `nil` when a title contains only spinner glyphs.
    ///
    /// - Parameter rawTitle: The title received from the terminal runtime.
    /// - Returns: The unchanged ordinary title, its spinner-free label, or `nil`
    ///   when no label remains after normalization.
    public func stableTitle(for rawTitle: String) -> String? {
        let characters = Array(rawTitle)
        guard !characters.isEmpty else { return rawTitle }
        guard !containsGlyphRun(characters) else { return rawTitle }

        var kept: [Character] = []
        var removedFrame = false
        for (index, character) in characters.enumerated() {
            if isKnownSpinnerFrame(character), isStandaloneToken(at: index, in: characters) {
                removedFrame = true
                continue
            }
            kept.append(character)
        }
        guard removedFrame else { return rawTitle }

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
        // Asterisk frames, which is what Claude Code animates.
        case 0x2731...0x273D:
            return true
        // Half-filled and quadrant circle frames.
        case 0x25D0...0x25D3, 0x25F4...0x25F7:
            return true
        default:
            return false
        }
    }

    private func brailleScalarValue(for character: Character) -> UInt32? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return nil
        }
        guard (0x2800...0x28FF).contains(scalar.value) else { return nil }
        return scalar.value
    }
}
