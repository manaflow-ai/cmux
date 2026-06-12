import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation


// MARK: - Notification Hook Definitions
enum CmuxNotificationHooksMode: String, Codable, Sendable, Hashable {
    case append
    case replace
}

struct CmuxNotificationConfigDefinition: Codable, Sendable, Hashable {
    var hooks: [CmuxNotificationHookDefinition]?
    var hooksMode: CmuxNotificationHooksMode?

    private enum CodingKeys: String, CodingKey {
        case hooks
        case hooksMode
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

struct CmuxResolvedNotificationHook: Sendable, Hashable {
    let id: String
    let command: String
    let timeoutSeconds: TimeInterval
    let sourcePath: String?
    let cwd: String
    let trustDescriptor: CmuxActionTrustDescriptor?

    init(
        id: String,
        command: String,
        timeoutSeconds: TimeInterval,
        sourcePath: String?,
        cwd: String,
        trustDescriptor: CmuxActionTrustDescriptor? = nil
    ) {
        self.id = id
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.sourcePath = sourcePath
        self.cwd = cwd
        self.trustDescriptor = trustDescriptor
    }

    static func == (lhs: CmuxResolvedNotificationHook, rhs: CmuxResolvedNotificationHook) -> Bool {
        lhs.id == rhs.id &&
            lhs.command == rhs.command &&
            lhs.timeoutSeconds == rhs.timeoutSeconds &&
            lhs.sourcePath == rhs.sourcePath &&
            lhs.cwd == rhs.cwd &&
            lhs.trustDescriptor?.fingerprint == rhs.trustDescriptor?.fingerprint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(command)
        hasher.combine(timeoutSeconds)
        hasher.combine(sourcePath)
        hasher.combine(cwd)
        hasher.combine(trustDescriptor?.fingerprint)
    }
}

