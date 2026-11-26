import Foundation

/// Versioned, lossless identity for one agent Feed workstream.
///
/// Both components are Base64 encoded and separated by a character outside
/// the Base64 alphabet. Agent and session identifiers may therefore contain
/// arbitrary punctuation—including the hyphens used by `hermes-agent`—without
/// making the boundary ambiguous.
public struct FeedWorkstreamIdentifier: Hashable, RawRepresentable, Sendable {
    private static let prefix = "cmux-feed-v1:"

    /// The stable agent-registry identifier component.
    public let agentID: String
    /// The agent-owned session identifier component.
    public let sessionID: String
    /// The versioned wire representation used in Feed events.
    public let rawValue: String

    /// Creates a versioned identifier from one safe agent id and non-empty session id.
    ///
    /// - Parameters:
    ///   - agentID: The registry id used to select the hook-session store file.
    ///   - sessionID: The opaque session id supplied by the agent.
    /// - Returns: `nil` when the agent component is unsafe or either component is empty.
    public init?(agentID: String, sessionID: String) {
        // The agent component is also used to select the legacy hook-session
        // filename during compatibility resolution. Keep the versioned
        // producer from emitting an identifier that the resolver can never
        // safely read, while leaving session identifiers lossless.
        guard Self.isSafeAgentComponent(agentID), !sessionID.isEmpty else { return nil }
        self.agentID = agentID
        self.sessionID = sessionID
        self.rawValue = Self.prefix
            + Self.encode(agentID)
            + ":"
            + Self.encode(sessionID)
    }

    /// Decodes a versioned wire identifier.
    ///
    /// - Parameter rawValue: The `cmux-feed-v1:` encoded value.
    /// - Returns: `nil` when the prefix, Base64 components, or safety rules do not match.
    public init?(rawValue: String) {
        guard rawValue.hasPrefix(Self.prefix) else { return nil }
        let payload = rawValue.dropFirst(Self.prefix.count)
        let components = payload.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let agentID = Self.decode(components[0]),
              let sessionID = Self.decode(components[1]),
              Self.isSafeAgentComponent(agentID),
              !sessionID.isEmpty else {
            return nil
        }
        self.agentID = agentID
        self.sessionID = sessionID
        self.rawValue = rawValue
    }

    /// Returns the canonical v1 value for either a legacy or versioned id.
    ///
    /// Older cmux builds persisted workstream ids as
    /// `agentID-sessionID`. The session component is opaque and may contain
    /// hyphens, so the agent prefix is removed exactly once. Values that are
    /// already versioned, unrelated to `agentID`, or malformed are returned
    /// unchanged so callers can preserve unknown history.
    ///
    /// - Parameters:
    ///   - agentID: The source/registry id that owns the workstream.
    ///   - rawValue: A legacy or versioned workstream id.
    /// - Returns: A v1 id when the legacy value can be safely converted.
    public static func canonicalizedRawValue(
        agentID: String,
        rawValue: String
    ) -> String {
        if let versioned = Self(rawValue: rawValue), versioned.agentID == agentID {
            return versioned.rawValue
        }
        let legacyPrefix = agentID + "-"
        guard rawValue.hasPrefix(legacyPrefix) else { return rawValue }
        let sessionID = String(rawValue.dropFirst(legacyPrefix.count))
        guard let versioned = Self(agentID: agentID, sessionID: sessionID) else {
            return rawValue
        }
        return versioned.rawValue
    }

    private static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func decode(_ value: Substring) -> String? {
        guard let data = Data(base64Encoded: String(value)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isSafeAgentComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return !value.contains { character in
            character == "/" || character == "\\" || character.isNewline
        }
    }
}
