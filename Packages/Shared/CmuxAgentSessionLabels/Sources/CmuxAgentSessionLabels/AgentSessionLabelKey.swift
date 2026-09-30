import Foundation

/// Identifies the session a label belongs to.
///
/// A session id is unique only within the agent that issued it, so a label is
/// keyed by both. Neither part is a path component: the store nests them inside
/// one JSON document, so a session id holding a `/` or a `..` names a record and
/// never a file.
public struct AgentSessionLabelKey: Sendable, Hashable, Comparable {
    /// The agent that issued the session, as `cmux sessions` reports it.
    public let agent: String
    /// The session id the agent wrote.
    public let sessionID: String

    /// - Throws: ``AgentSessionLabelError`` when either part is empty or holds a
    ///   control character, which would make a record unaddressable from the
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
        if let offending = trimmed.unicodeScalars.first(where: {
            $0.properties.generalCategory == .control
        }) {
            throw AgentSessionLabelError.disallowedCharacter(scalar: offending)
        }
        return trimmed
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.agent, lhs.sessionID) < (rhs.agent, rhs.sessionID)
    }
}
