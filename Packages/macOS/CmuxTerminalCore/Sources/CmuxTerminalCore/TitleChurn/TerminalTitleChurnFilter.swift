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
              brailleScalarValue(for: labelStart) == nil else {
            return rawTitle
        }
        return String(remainder)
    }

    private func isKnownSpinnerFrame(_ character: Character) -> Bool {
        guard let value = brailleScalarValue(for: character) else { return false }
        switch value {
        case 0x280B, 0x2819, 0x2839, 0x2838, 0x283C,
             0x2834, 0x2826, 0x2827, 0x2807, 0x280F:
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
