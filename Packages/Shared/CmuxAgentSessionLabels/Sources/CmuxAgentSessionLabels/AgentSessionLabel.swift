public import Foundation

/// A cmux-authored display name for one agent session.
///
/// Agent sessions arrive from each agent's own files, and none of those records
/// carries a name cmux may write: the hook-session payloads have no title field,
/// and hooks rewrite them. A label is the cmux-owned side of that, which is why
/// it validates on the way in rather than on the way out to a sidebar row.
///
/// ```swift
/// let label = try AgentSessionLabel(text: "auditing the socket rows", updatedAt: .now)
/// print(label.text)
/// ```
public struct AgentSessionLabel: Sendable, Hashable {
    /// The longest label this type accepts, in characters.
    ///
    /// A label is read in one line, next to a session's agent and working
    /// directory, both in `cmux sessions` output and in the vault sidebar. Past
    /// this length it is not a name any more, and the line it shares stops being
    /// readable.
    ///
    /// This counts characters, so it does not bound how wide a label renders: a
    /// label of 120 CJK characters or flag emoji is about 240 terminal columns.
    /// ``maximumByteCount`` is what bounds the stored size.
    public static let maximumLength = 120

    /// The largest UTF-8 size this type accepts, in bytes.
    ///
    /// A character count alone does not bound size, because one character can
    /// carry any number of combining marks. Every label shares one document, so
    /// this is also what keeps the store from growing without limit. It is set
    /// well above any label a person would write by hand.
    public static let maximumByteCount = 512

    /// The label as it is shown, with leading and trailing whitespace removed.
    public let text: String
    /// When this label was last written, truncated to a whole second.
    ///
    /// The store writes ISO 8601 seconds, so a sub-second value would not
    /// survive the round trip and a caller comparing what it wrote against what
    /// it read back would see a change that did not happen.
    public let updatedAt: Date

    /// Creates a label from text a person typed.
    ///
    /// - Parameters:
    ///   - text: the label as typed. Leading and trailing spaces, tabs and
    ///     newlines are removed rather than refused, because a pasted name
    ///     usually carries some. A line or paragraph separator at an edge is
    ///     refused instead of trimmed, so this type never reports storing text
    ///     it would not accept in the middle of a label.
    ///   - updatedAt: when the label was written. Truncated to a whole second,
    ///     for the reason on ``updatedAt``.
    /// - Throws: ``AgentSessionLabelError/emptyLabel`` when `text` is empty once
    ///   trimmed, ``AgentSessionLabelError/labelTooLong(length:maximum:)`` or
    ///   ``AgentSessionLabelError/labelTooManyBytes(bytes:maximum:)`` when it is
    ///   past a limit, and
    ///   ``AgentSessionLabelError/disallowedCharacter(scalar:)`` when it holds a
    ///   character that would make the line it is printed on lie about itself.
    public init(text: String, updatedAt: Date) throws {
        let trimmed = AgentSessionLabelScalarRule.trimmed(text)
        guard !trimmed.isEmpty else { throw AgentSessionLabelError.emptyLabel }
        guard trimmed.count <= Self.maximumLength else {
            throw AgentSessionLabelError.labelTooLong(
                length: trimmed.count, maximum: Self.maximumLength
            )
        }
        let byteCount = trimmed.utf8.count
        guard byteCount <= Self.maximumByteCount else {
            throw AgentSessionLabelError.labelTooManyBytes(
                bytes: byteCount, maximum: Self.maximumByteCount
            )
        }
        if let offending = AgentSessionLabelScalarRule.firstRejected(in: trimmed) {
            throw AgentSessionLabelError.disallowedCharacter(scalar: offending)
        }
        self.text = trimmed
        self.updatedAt = Date(timeIntervalSince1970: updatedAt.timeIntervalSince1970.rounded(.down))
    }
}
