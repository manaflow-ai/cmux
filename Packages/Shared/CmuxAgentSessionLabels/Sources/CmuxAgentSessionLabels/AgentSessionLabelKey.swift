import Foundation

/// Identifies the session a label belongs to.
///
/// A session id is unique only within the agent that issued it, so a label is
/// keyed by both. Neither part is a path component: the store nests them inside
/// one JSON document, so a session id holding a `/` or a `..` names a record and
/// never a file.
///
/// ```swift
/// let key = try AgentSessionLabelKey(agent: "codex", sessionID: "s-1")
/// ```
public struct AgentSessionLabelKey: Sendable, Hashable, Comparable {
    /// The longest agent name or session id this type accepts, in characters.
    ///
    /// Both parts are printed beside the label, and both come from another
    /// program's files, so they get a bound of their own. Agent names are short
    /// words and session ids are usually UUIDs, so this is far above either.
    public static let maximumFieldLength = 200

    /// The agent that issued the session, as `cmux sessions` reports it.
    public let agent: String
    /// The session id the agent wrote.
    public let sessionID: String

    /// Creates a key, refusing the parts a listing row could not print honestly.
    ///
    /// - Parameters:
    ///   - agent: the agent name. Surrounding whitespace is removed.
    ///   - sessionID: the agent's own session id. Surrounding whitespace is
    ///     removed, so an id copied out of a listing still matches.
    /// - Throws: ``AgentSessionLabelError/emptyKeyField(field:)`` for an empty
    ///   part, ``AgentSessionLabelError/keyFieldTooLong(field:length:maximum:)``
    ///   past ``maximumFieldLength``, and
    ///   ``AgentSessionLabelError/disallowedCharacter(scalar:)`` for a character
    ///   that would make the row it is printed on lie about itself, including the
    ///   control characters that would make a record unaddressable from the
    ///   command line that has to clear it later.
    public init(agent: String, sessionID: String) throws {
        self.agent = try Self.validated(agent, field: "agent")
        self.sessionID = try Self.validated(sessionID, field: "session id")
    }

    private static func validated(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentSessionLabelError.emptyKeyField(field: field)
        }
        guard trimmed.count <= maximumFieldLength else {
            throw AgentSessionLabelError.keyFieldTooLong(
                field: field, length: trimmed.count, maximum: maximumFieldLength
            )
        }
        if let offending = AgentSessionLabelScalarRule.firstRejected(in: trimmed) {
            throw AgentSessionLabelError.disallowedCharacter(scalar: offending)
        }
        return trimmed
    }

    /// Orders by agent, then by session id, which is the order a listing prints.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.agent, lhs.sessionID) < (rhs.agent, rhs.sessionID)
    }
}
