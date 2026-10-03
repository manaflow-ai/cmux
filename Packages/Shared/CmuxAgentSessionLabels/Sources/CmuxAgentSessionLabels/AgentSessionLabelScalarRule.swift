import Foundation

/// Which scalars a label and a key may hold.
///
/// One rule, applied to both, because a listing row carries the label *and* the
/// agent name and session id beside it: a scalar that reverses the row does the
/// same damage whichever field it sits in.
enum AgentSessionLabelScalarRule {
    /// Invisible scalars that are allowed anyway.
    ///
    /// A label is a name a person chose, so the rule has to let through the
    /// invisible scalars names are actually written with. U+200D joins emoji, and
    /// the three direction marks set the direction of the text beside them, which
    /// is how a Hebrew or Arabic label embeds a file name. None of them reaches
    /// past the field it sits in, unlike the overrides below.
    private static let allowedInvisibleScalars: Set<Unicode.Scalar> = [
        Unicode.Scalar(0x200D)!,  // zero width joiner
        Unicode.Scalar(0x200E)!,  // left-to-right mark
        Unicode.Scalar(0x200F)!,  // right-to-left mark
        Unicode.Scalar(0x061C)!   // arabic letter mark
    ]

    /// The tag scalars that spell out a subdivision flag, as in the Scotland flag
    /// emoji. They are formatting scalars, and refusing them would refuse a flag
    /// someone pasted over a scalar they cannot see and did not type.
    private static let emojiTagScalars: ClosedRange<UInt32> = 0xE0020...0xE007F

    /// Whether a scalar may not appear.
    ///
    /// Controls, including the newline and tab that would break a one-line
    /// listing into two rows; the line and paragraph separators, which are line
    /// breaks everywhere this text is drawn; and the formatting scalars, which can
    /// make text render as something it does not contain, as a zero-width space
    /// hides a word boundary and a right-to-left override reverses the rest of the
    /// row.
    ///
    /// - Parameter scalar: the scalar to judge.
    /// - Returns: `true` when it must be refused.
    static func rejects(_ scalar: Unicode.Scalar) -> Bool {
        if allowedInvisibleScalars.contains(scalar) { return false }
        if emojiTagScalars.contains(scalar.value) { return false }
        // `.surrogate` is deliberately absent: `Unicode.Scalar` cannot hold a
        // surrogate value, so a case for it would never run.
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    /// The characters a label or a key may carry at its edges and lose.
    ///
    /// A pasted name arrives with spaces, tabs and a newline around it, and
    /// removing those is friendlier than refusing the paste. The line and
    /// paragraph separators are not in here even though
    /// `whitespacesAndNewlines` holds them: they are scalars ``rejects(_:)``
    /// refuses, and trimming them at an edge would report success for text this
    /// type says it does not store. Whatever is trimmed here is therefore
    /// narrower than what is rejected, so the two rules cannot disagree.
    static let trimmableCharacters: CharacterSet = CharacterSet.whitespacesAndNewlines
        .subtracting(CharacterSet(charactersIn: "\u{2028}\u{2029}\u{0085}"))

    /// `text` without the edge characters this type drops.
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: trimmableCharacters)
    }

    /// The first scalar of `text` that must be refused, if there is one.
    static func firstRejected(in text: String) -> Unicode.Scalar? {
        text.unicodeScalars.first(where: rejects)
    }
}
