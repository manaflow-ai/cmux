public import Foundation

/// Local-only command payload. Socket authorization and relay denial are enforced by the caller.
public enum OwnedAttentionCommand: Codable, Sendable {
    case register(producer: UUID, capability: Data, epoch: UUID)
    case read(producer: UUID, capability: Data)
    case set(producer: UUID, capability: Data, epoch: UUID, revision: String, destinations: [OwnedAttentionDestination])
    case resume(producer: UUID, capability: Data, expectedEpoch: UUID, requestID: UUID)

    private enum Keys: String, CodingKey {
        case action, producer, capability, epoch, revision, destinations
        case expectedEpoch = "expected_epoch"
        case requestID = "request_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let action = try container.decode(String.self, forKey: .action)
        let producer = try container.decode(UUID.self, forKey: .producer)
        let capability = try container.decode(Data.self, forKey: .capability)
        switch action {
        case "register": self = .register(producer: producer, capability: capability, epoch: try container.decode(UUID.self, forKey: .epoch))
        case "read": self = .read(producer: producer, capability: capability)
        case "set": self = .set(producer: producer, capability: capability, epoch: try container.decode(UUID.self, forKey: .epoch), revision: try container.decode(String.self, forKey: .revision), destinations: try container.decode([OwnedAttentionDestination].self, forKey: .destinations))
        case "resume": self = .resume(producer: producer, capability: capability, expectedEpoch: try container.decode(UUID.self, forKey: .expectedEpoch), requestID: try container.decode(UUID.self, forKey: .requestID))
        default: throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "Unknown owned attention action")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .register(producer, capability, epoch):
            try container.encode("register", forKey: .action)
            try container.encode(producer, forKey: .producer)
            try container.encode(capability, forKey: .capability)
            try container.encode(epoch, forKey: .epoch)
        case let .read(producer, capability):
            try container.encode("read", forKey: .action)
            try container.encode(producer, forKey: .producer)
            try container.encode(capability, forKey: .capability)
        case let .set(producer, capability, epoch, revision, destinations):
            try container.encode("set", forKey: .action)
            try container.encode(producer, forKey: .producer)
            try container.encode(capability, forKey: .capability)
            try container.encode(epoch, forKey: .epoch)
            try container.encode(revision, forKey: .revision)
            try container.encode(destinations, forKey: .destinations)
        case let .resume(producer, capability, expectedEpoch, requestID):
            try container.encode("resume", forKey: .action)
            try container.encode(producer, forKey: .producer)
            try container.encode(capability, forKey: .capability)
            try container.encode(expectedEpoch, forKey: .expectedEpoch)
            try container.encode(requestID, forKey: .requestID)
        }
    }
}

public enum OwnedAttentionCommandError: Error, Equatable, Sendable {
    case requestTooLarge, invalidRevision, targetDenied, storeMismatch, leaseHeld
}

/// The producer persists this identity before sending a registration or update.
public struct OwnedAttentionCommandEnvelope: Codable, Sendable {
    public let storeID: UUID
    public let command: OwnedAttentionCommand
    private enum Keys: String, CodingKey { case storeID = "store_id" }

    public init(storeID: UUID, command: OwnedAttentionCommand) {
        self.storeID = storeID
        self.command = command
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        storeID = try container.decode(UUID.self, forKey: .storeID)
        command = try OwnedAttentionCommand(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(storeID, forKey: .storeID)
        try command.encode(to: encoder)
    }
}

public struct OwnedAttentionCommandResult: Encodable, Sendable {
    public let state: OwnedAttentionState?
    /// Even a retry requests reconciliation: a previous projection may have been interrupted.
    public let projectionRequired: Bool

    private enum Keys: String, CodingKey { case state }
    private enum StateKeys: String, CodingKey { case epoch, revision, destinations }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        guard let state else { try container.encodeNil(forKey: .state); return }
        var value = container.nestedContainer(keyedBy: StateKeys.self, forKey: .state)
        try value.encode(state.epoch, forKey: .epoch)
        try value.encode(String(state.revision), forKey: .revision)
        try value.encode(state.destinations, forKey: .destinations)
    }
}

/// Invoke on a socket worker, never on the main actor: mutations can fsync.
public struct OwnedAttentionCommandHandler: Sendable {
    public static let maximumRequestBytes = 3 * 1024 * 1024
    private let repository: OwnedAttentionRepository
    private let expectedStoreID: UUID
    private let authorizeDestination: @Sendable (UUID, OwnedAttentionDestination) -> Bool

    public init(repository: OwnedAttentionRepository, expectedStoreID: UUID, authorizeDestination: @escaping @Sendable (UUID, OwnedAttentionDestination) -> Bool) {
        self.repository = repository
        self.expectedStoreID = expectedStoreID
        self.authorizeDestination = authorizeDestination
    }

    public func handleEnvelope(_ data: Data) throws -> OwnedAttentionCommandResult {
        guard data.count <= Self.maximumRequestBytes else { throw OwnedAttentionCommandError.requestTooLarge }
        let envelope = try JSONDecoder().decode(OwnedAttentionCommandEnvelope.self, from: data)
        guard envelope.storeID == expectedStoreID else { throw OwnedAttentionCommandError.storeMismatch }
        return try perform(envelope.command)
    }

    func handle(_ data: Data) throws -> OwnedAttentionCommandResult {
        guard data.count <= Self.maximumRequestBytes else { throw OwnedAttentionCommandError.requestTooLarge }
        return try perform(JSONDecoder().decode(OwnedAttentionCommand.self, from: data))
    }

    private func perform(_ command: OwnedAttentionCommand) throws -> OwnedAttentionCommandResult {
        guard try repository.storeIdentity() == expectedStoreID else { throw OwnedAttentionCommandError.storeMismatch }
        switch command {
        case let .register(producer, capability, epoch):
            try repository.register(producer: producer, capability: capability, epoch: epoch)
            return OwnedAttentionCommandResult(state: nil, projectionRequired: true)
        case let .read(producer, capability):
            return OwnedAttentionCommandResult(state: try repository.read(producer: producer, capability: capability), projectionRequired: false)
        case let .set(producer, capability, epoch, revision, destinations):
            guard let number = UInt64(revision), String(number) == revision else { throw OwnedAttentionCommandError.invalidRevision }
            // Resolve live targets outside the transaction; compare the denied targets
            // with the committed state inside it so concurrent writers cannot bypass
            // authorization by changing that state between the check and the write.
            let denied = destinations.filter { !authorizeDestination(producer, $0) }
            try repository.apply(producer: producer, capability: capability, epoch: epoch, revision: number, destinations: destinations) { current in
                guard denied.allSatisfy({ current.destinations.contains($0) }) else {
                    throw OwnedAttentionCommandError.targetDenied
                }
            }
            return OwnedAttentionCommandResult(state: nil, projectionRequired: true)
        case let .resume(producer, capability, expectedEpoch, requestID):
            return OwnedAttentionCommandResult(state: try repository.resume(producer: producer, capability: capability, expectedEpoch: expectedEpoch, requestID: requestID), projectionRequired: true)
        }
    }
}
