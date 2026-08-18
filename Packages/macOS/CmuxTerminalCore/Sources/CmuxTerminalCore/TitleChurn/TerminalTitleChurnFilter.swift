/// Normalizes animated terminal titles before title-update deduplication.
///
/// Command-line spinners commonly prefix a stable label with one of ten
/// Braille Pattern frames. Collapsing that standalone animation token makes
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
        guard let first = remainder.first, isKnownSpinnerFrame(first) else {
            return rawTitle
        }
        remainder = remainder.dropFirst()
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else {
            return rawTitle
        }
        while remainder.first?.isWhitespace == true {
            remainder = remainder.dropFirst()
        }
        guard !remainder.isEmpty else { return nil }
        guard let labelStart = remainder.first,
              brailleScalarValue(for: labelStart) == nil,
              !isKnownSpinnerFrame(labelStart) else {
            return rawTitle
        }
        return String(remainder)
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

    private func brailleScalarValue(for character: Character) -> UInt32? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return nil
        }
        guard (0x2800...0x28FF).contains(scalar.value) else { return nil }
        return scalar.value
    }
}
