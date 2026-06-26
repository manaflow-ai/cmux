import Foundation

/// A single notification hook declared in a `cmux.json` `notifications.hooks`
/// array.
///
/// Pure value type. Decoding trims and validates `id` and `command` (both must
/// be non-blank) and rejects a non-finite or non-positive `timeoutSeconds`; an
/// omitted `enabled` defaults to `true` and an omitted `timeoutSeconds` resolves
/// to ``defaultTimeoutSeconds`` via ``resolvedTimeoutSeconds``.
public struct CmuxNotificationHookDefinition: Codable, Sendable, Hashable {
    /// The fallback timeout, in seconds, applied when a hook omits `timeoutSeconds`.
    public static let defaultTimeoutSeconds: TimeInterval = 20

    /// The hook's stable identifier.
    public var id: String
    /// The shell command the hook runs.
    public var command: String
    /// The hook's timeout in seconds, or `nil` to use ``defaultTimeoutSeconds``.
    public var timeoutSeconds: TimeInterval?
    /// Whether the hook is enabled.
    public var enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case command
        case timeoutSeconds
        case enabled
    }

    /// Creates a notification hook definition.
    /// - Parameters:
    ///   - id: The hook's stable identifier.
    ///   - command: The shell command the hook runs.
    ///   - timeoutSeconds: The hook's timeout in seconds, or `nil` for the default.
    ///   - enabled: Whether the hook is enabled.
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

    /// The effective timeout, falling back to ``defaultTimeoutSeconds`` when
    /// `timeoutSeconds` is `nil`.
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
