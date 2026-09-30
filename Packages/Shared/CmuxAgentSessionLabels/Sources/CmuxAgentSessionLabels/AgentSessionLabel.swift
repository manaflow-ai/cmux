import Foundation

/// A cmux-authored display name for one agent session.
///
/// Agent sessions arrive from each agent's own files, and none of those records
/// carries a name cmux may write: the hook-session payloads have no title field,
/// and hooks rewrite them. A label is the cmux-owned side of that, which is why
/// it validates on the way in rather than on the way out to a sidebar row.
public struct AgentSessionLabel: Sendable, Hashable {
    /// The longest label this type accepts, in characters.
    ///
    /// A label is read in one line, next to a session's agent and working
    /// directory, both in `cmux sessions` output and in the vault sidebar. Past
    /// this length it is not a name any more, and the line it shares stops being
    /// readable.
    public static let maximumLength = 120

    /// The label as it is shown, with leading and trailing whitespace removed.
    public let text: String
    /// When this label was last written.
    public let updatedAt: Date

    /// Creates a label from text a person typed.
    ///
    /// - Throws: ``AgentSessionLabelError`` when `text` is empty once trimmed,
    ///   longer than ``maximumLength``, or holds a character that would make the
    ///   line it is printed on lie about itself.
    public init(text: String, updatedAt: Date) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentSessionLabelError.emptyLabel }
        guard trimmed.count <= Self.maximumLength else {
            throw AgentSessionLabelError.labelTooLong(
                length: trimmed.count, maximum: Self.maximumLength
            )
        }
        if let offending = trimmed.unicodeScalars.first(where: Self.isRejected) {
            throw AgentSessionLabelError.disallowedCharacter(scalar: offending)
        }
        self.text = trimmed
        self.updatedAt = updatedAt
    }

    /// The one invisible scalar a label may contain.
    ///
    /// Emoji are joined with it, and a label is a name a person chose, so
    /// rejecting every invisible scalar would reject "👩‍💻" for no reason.
    private static let zeroWidthJoiner = Unicode.Scalar(0x200D)

    /// Whether a scalar may not appear in a label.
    ///
    /// Controls, including the newline and tab that would break a one-line
    /// listing into two rows, and the formatting scalars, which can make a label
    /// render as text it does not contain: a zero-width space hides a word
    /// boundary, and a right-to-left override reverses the rest of the row.
    private static func isRejected(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == zeroWidthJoiner { return false }
        if scalar.properties.isBidiControl { return true }
        return scalar.properties.generalCategory == .control
            || scalar.properties.generalCategory == .format
    }
}
