import Foundation

/// A session-scoped agent runtime key with an unambiguous status-key boundary.
///
/// Legacy runtime keys used `<status-key>.<session-id>`, which cannot be parsed
/// when registered agent identifiers themselves contain dots. This encoding
/// keeps the status key readable while marking the boundary with `~`, a
/// character that registered agent identifiers cannot contain, and encodes the
/// session id as a URL-safe Base64 token.
///
/// ```swift
/// let key = AgentRuntimeSessionKey(
///     statusKey: "acme.agent",
///     sessionID: "session-a"
/// )
/// AgentRuntimeSessionKey(rawValue: key.rawValue) == key
/// ```
public struct AgentRuntimeSessionKey: Hashable, Sendable {
    private static let boundary = ".~cmux-session-v1~."

    /// The inherited environment key carrying a restored runtime's immutable generation.
    public static let runtimeGenerationEnvironmentKey = "CMUX_AGENT_RUNTIME_GENERATION"

    /// The kind-scoped sidebar status and lifecycle key.
    public let statusKey: String

    /// The exact agent conversation identifier.
    public let sessionID: String

    /// Creates a session-scoped runtime key.
    ///
    /// - Parameters:
    ///   - statusKey: The kind-scoped sidebar status and lifecycle key.
    ///   - sessionID: The exact agent conversation identifier.
    public init(statusKey: String, sessionID: String) {
        self.statusKey = statusKey
        self.sessionID = sessionID
    }

    /// Decodes a versioned session-scoped runtime key.
    ///
    /// Legacy dotted keys deliberately return `nil`; callers that support
    /// mixed-version hooks must handle those using an already-known binding,
    /// never by guessing where a dotted agent identifier ends.
    ///
    /// - Parameter rawValue: The runtime key sent through `set_agent_pid`.
    public init?(rawValue: String) {
        guard let boundaryRange = rawValue.range(
            of: Self.boundary,
            options: .backwards
        ) else {
            return nil
        }
        let statusKey = String(rawValue[..<boundaryRange.lowerBound])
        let encodedSessionID = String(rawValue[boundaryRange.upperBound...])
        guard !statusKey.isEmpty,
              !encodedSessionID.isEmpty,
              encodedSessionID.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
              }) else {
            return nil
        }
        var base64 = encodedSessionID
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingCount = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: paddingCount))
        guard let data = Data(base64Encoded: base64),
              let sessionID = String(data: data, encoding: .utf8),
              !sessionID.isEmpty else {
            return nil
        }
        self.init(statusKey: statusKey, sessionID: sessionID)
    }

    /// The command-safe representation sent through `set_agent_pid`.
    public var rawValue: String {
        let encodedSessionID = Data(sessionID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return statusKey + Self.boundary + encodedSessionID
    }

    /// Structured and legacy exact-session keys cleared during mixed-version teardown.
    public var compatibleRawValues: [String] {
        let legacyRawValue = "\(statusKey).\(sessionID)"
        guard legacyRawValue.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }) else {
            return [rawValue]
        }
        return [rawValue, legacyRawValue]
    }

    /// Returns a validated runtime generation from a restored process environment.
    ///
    /// - Parameter environment: The environment inherited by an agent hook process.
    /// - Returns: A finite positive generation, or `nil` when the environment does not carry one.
    public static func inheritedRuntimeGeneration(
        from environment: [String: String]
    ) -> TimeInterval? {
        guard let rawValue = environment[runtimeGenerationEnvironmentKey],
              let generation = TimeInterval(rawValue),
              generation.isFinite,
              generation > 0 else {
            return nil
        }
        return generation
    }
}
