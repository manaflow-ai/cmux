import Foundation

enum CmuxNotificationHooksMode: String, Codable, Sendable, Hashable {
    case append
    case replace
}

struct CmuxNotificationConfigDefinition: Codable, Sendable, Hashable {
    var hooks: [CmuxNotificationHookDefinition]?
    var hooksMode: CmuxNotificationHooksMode?
    var muteDurations: [CmuxNotificationMuteDurationDefinition]?

    private enum CodingKeys: String, CodingKey {
        case hooks
        case hooksMode
        case muteDurations
    }
}

struct CmuxNotificationMuteDurationDefinition: Codable, Sendable, Hashable {
    var label: String
    var interval: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case label
        case seconds
        case minutes
        case hours
    }

    init(label: String, interval: TimeInterval) {
        self.label = label
        self.interval = interval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedLabel = try Self.requiredTrimmedString(forKey: .label, in: container)
        let seconds = try container.decodeIfPresent(TimeInterval.self, forKey: .seconds)
        let minutes = try container.decodeIfPresent(TimeInterval.self, forKey: .minutes)
        let hours = try container.decodeIfPresent(TimeInterval.self, forKey: .hours)
        for (key, value) in [(CodingKeys.seconds, seconds), (.minutes, minutes), (.hours, hours)] {
            if let value, (!value.isFinite || value <= 0) {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "\(key.stringValue) must be greater than 0"
                )
            }
        }
        let decodedInterval = (seconds ?? 0) + ((minutes ?? 0) * 60) + ((hours ?? 0) * 60 * 60)
        if decodedInterval <= 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .seconds,
                in: container,
                debugDescription: "mute duration must be greater than 0 seconds"
            )
        }

        label = decodedLabel
        interval = decodedInterval
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(interval, forKey: .seconds)
    }

    private static func requiredTrimmedString<Key: CodingKey>(
        forKey key: Key,
        in container: KeyedDecodingContainer<Key>
    ) throws -> String {
        let value = try container.decode(String.self, forKey: key).trimmingCharacters(in: .whitespacesAndNewlines)
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

struct CmuxNotificationHookDefinition: Codable, Sendable, Hashable {
    static let defaultTimeoutSeconds: TimeInterval = 20

    var id: String
    var command: String
    var timeoutSeconds: TimeInterval?
    var enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case command
        case timeoutSeconds
        case enabled
    }

    init(
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(enabled, forKey: .enabled)
    }

    var resolvedTimeoutSeconds: TimeInterval {
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
