public import Foundation

public struct OwnedAttentionExecution: Sendable {
    public let result: OwnedAttentionCommandResult
    public let snapshot: OwnedAttentionSnapshot?
}

/// In-memory ownership for authenticated, live control-socket connections.
/// Callers must authenticate a producer before acquiring its lease and release
/// the connection only after its last command has finished. All operations run
/// on a blocking worker because a command may perform synchronous storage I/O.
public final class OwnedAttentionLeases: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [UUID: UUID] = [:]

    public init() {}

    func acquire(producer: UUID, connection: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acquireUnlocked(producer: producer, connection: connection)
    }

    private func acquireUnlocked(producer: UUID, connection: UUID) -> Bool {
        if let owner = owners[producer] {
            return owner == connection
        }
        owners[producer] = connection
        return true
    }

    public func release(connection: UUID) {
        lock.lock()
        defer { lock.unlock() }
        owners = owners.filter { $0.value != connection }
    }

    /// Serializes authentication, ownership, and command execution together.
    /// The caller releases the connection after its command loop has stopped.
    public func handle(
        _ data: Data,
        connection: UUID,
        repository: OwnedAttentionRepository,
        handler: OwnedAttentionCommandHandler
    ) throws -> OwnedAttentionCommandResult {
        try execute(data, connection: connection, repository: repository, handler: handler).result
    }

    /// Returns the committed state for projection while ordering the snapshot
    /// after the command and before any later command on this lease manager.
    public func execute(
        _ data: Data,
        connection: UUID,
        repository: OwnedAttentionRepository,
        handler: OwnedAttentionCommandHandler
    ) throws -> OwnedAttentionExecution {
        lock.lock()
        defer { lock.unlock() }
        guard data.count <= OwnedAttentionCommandHandler.maximumRequestBytes else {
            throw OwnedAttentionCommandError.requestTooLarge
        }
        let envelope = try JSONDecoder().decode(OwnedAttentionCommandEnvelope.self, from: data)
        guard envelope.storeID == (try repository.storeIdentity()) else {
            throw OwnedAttentionCommandError.storeMismatch
        }
        let producer: UUID
        let capability: Data
        let registrationResult: OwnedAttentionCommandResult?
        switch envelope.command {
        case let .register(id, secret, _):
            // Registration is idempotent and validates the capability for an
            // existing producer before its connection can claim ownership.
            registrationResult = try handler.handleEnvelope(data)
            producer = id
            capability = secret
        case let .read(id, secret), let .set(id, secret, _, _, _),
             let .resume(id, secret, _, _):
            registrationResult = nil
            producer = id
            capability = secret
        }
        _ = try repository.read(producer: producer, capability: capability)
        guard acquireUnlocked(producer: producer, connection: connection) else {
            throw OwnedAttentionCommandError.leaseHeld
        }
        let result = try registrationResult ?? handler.handleEnvelope(data)
        let snapshot = result.projectionRequired ? try repository.projectionSnapshot() : nil
        return OwnedAttentionExecution(result: result, snapshot: snapshot)
    }
}
