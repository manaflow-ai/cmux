public import Foundation

/// A single notification hook parsed from a `cmux.json` `notifications.hooks`
/// entry: a shell command run on a notification, with an id, an optional
/// per-hook timeout, and an enabled flag.
///
/// Decoding trims and rejects blank `id`/`command` and rejects a
/// non-finite or non-positive `timeoutSeconds`, matching the wire contract of
/// the original `CmuxConfig` schema byte-for-byte.
public struct CmuxNotificationHookDefinition: Codable, Sendable, Hashable {
    /// The timeout applied to a hook that does not specify `timeoutSeconds`.
    public static let defaultTimeoutSeconds: TimeInterval = 20

    /// Stable identifier for the hook within its config scope.
    public var id: String
    /// The shell command to run when the hook fires.
    public var command: String
    /// An optional per-hook timeout; falls back to `defaultTimeoutSeconds`.
    public var timeoutSeconds: TimeInterval?
    /// Whether the hook is active. Defaults to `true` when absent.
    public var enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case command
        case timeoutSeconds
        case enabled
    }

    /// Creates a notification hook definition.
    public init(
        id: String,
        command: String,
        timeoutSeconds: TimeInterval? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try Self.requiredTrimmedString(forKey: .id, in: container)
        let decodedCommand = try Self.requiredTrimmedString(forKey: .command, in: container)
        let decodedTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds)
        if let decodedTimeout, !decodedTimeout.isFinite || decodedTimeout <= 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .timeoutSeconds,
                in: container,
                debugDescription: "timeoutSeconds must be greater than 0"
            )
        }

        id = decodedID
        command = decodedCommand
        timeoutSeconds = decodedTimeout
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(enabled, forKey: .enabled)
    }

    /// The effective timeout for this hook, defaulting when unspecified.
    public var resolvedTimeoutSeconds: TimeInterval {
        timeoutSeconds ?? Self.defaultTimeoutSeconds
    }

    private static func requiredTrimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        let value = try container.decode(String.self, forKey: key)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return value
    }
}
