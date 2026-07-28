/// Normalizes animated terminal titles before title-update deduplication.
///
/// Command-line spinners commonly prefix a stable label with a changing
/// Braille Pattern glyph. Collapsing that leading animation token makes
/// successive frames equal while preserving ordinary titles byte-for-byte.
public struct TerminalTitleChurnFilter: Sendable {
    /// Creates a stateless terminal-title normalizer.
    public init() {}

    /// Returns a stable title, or `nil` when a title contains only spinner glyphs.
    ///
    /// - Parameter rawTitle: The title received from the terminal runtime.
    /// - Returns: The unchanged ordinary title, its spinner-free label, or `nil`
    ///   when no label remains after normalization.
    public func stableTitle(for rawTitle: String) -> String? {
        var remainder = rawTitle[...]
        while remainder.first?.isWhitespace == true {
            remainder = remainder.dropFirst()
        }
        guard let first = remainder.first, isBraillePattern(first) else {
            return rawTitle
        }
        while let character = remainder.first, isBraillePattern(character) {
            remainder = remainder.dropFirst()
        }
        while remainder.first?.isWhitespace == true {
            remainder = remainder.dropFirst()
        }
        guard !remainder.isEmpty else { return nil }
        return String(remainder)
    }

    private func isBraillePattern(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        return (0x2800...0x28FF).contains(scalar.value)
    }
}
