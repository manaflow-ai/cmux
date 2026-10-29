public import Foundation
internal import SQLite3
internal import CryptoKit
internal import Darwin

/// A storage failure does not establish whether an operation was committed.
public enum OwnedAttentionRepositoryError: Error, Equatable, Sendable {
    case storage(String)
    case producerExists
    case unauthorized
    case conflictingResume
    case identityQuotaExceeded
    case producerQuotaExceeded
}

public struct OwnedAttentionSnapshot: Sendable {
    public let storeID: UUID
    public let generation: Int64
    public let states: [UUID: OwnedAttentionState]
    public let identities: [OwnedAttentionSlot: UUID]
}

/// Shares a successfully opened store; temporary failures remain retryable.
public final class OwnedAttentionRepositoryProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let open: @Sendable () throws -> OwnedAttentionRepository
    private var cached: OwnedAttentionRepository?

    public init(open: @escaping @Sendable () throws -> OwnedAttentionRepository) {
        self.open = open
    }

    public func repository() throws -> OwnedAttentionRepository {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let repository = try open()
        cached = repository
        return repository
    }
}

/// Durable value register. Authentication and display projection are separate concerns.
public final class OwnedAttentionRepository: @unchecked Sendable {
    private static let schema = "CREATE TABLE owned_attention (producer TEXT PRIMARY KEY NOT NULL, capability_hash TEXT NOT NULL, payload TEXT NOT NULL, resume_request TEXT, resume_epoch TEXT)"
    private static let identitySchema = "CREATE TABLE owned_attention_identity (producer TEXT NOT NULL, workspace TEXT NOT NULL, surface TEXT NOT NULL, notification TEXT NOT NULL UNIQUE, PRIMARY KEY (producer, workspace, surface))"
    private static let metadataSchema = "CREATE TABLE owned_attention_metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), generation INTEGER NOT NULL, store_id TEXT NOT NULL)"
    private let lock = NSLock()
    private let database: OpaquePointer

    /// Opens an existing register or atomically provisions a new one. A
    /// concurrent provisioner can win the hard-link race; never replace an
    /// existing or invalid register. Producers must pin the returned store ID.
    public static func openOrProvision(databaseURL: URL) throws -> OwnedAttentionRepository {
        func checked(_ repository: OwnedAttentionRepository) throws -> OwnedAttentionRepository {
            _ = try repository.storeIdentity()
            return repository
        }
        var info = stat()
        if lstat(databaseURL.path, &info) == 0 {
            let existing = try checked(OwnedAttentionRepository(databaseURL: databaseURL, create: false))
            // A previous provisioner may have published the name but failed
            // before syncing its parent directory. Complete that sync before
            // treating the reopened store identity as durable.
            try syncDirectory(databaseURL.deletingLastPathComponent())
            return existing
        }
        guard errno == ENOENT else {
            throw OwnedAttentionRepositoryError.storage("cannot inspect register file")
        }
        do {
            return try checked(OwnedAttentionRepository(databaseURL: databaseURL, create: true))
        } catch {
            // An existing, valid register may have appeared during provisioning.
            // If opening it also fails, preserve the original failure.
            if let existing = try? checked(OwnedAttentionRepository(databaseURL: databaseURL, create: false)) {
                try syncDirectory(databaseURL.deletingLastPathComponent())
                return existing
            }
            throw error
        }
    }

    /// `create` is reserved for an explicitly provisioned new register.
    public convenience init(databaseURL: URL, create: Bool) throws {
        try self.init(databaseURL: databaseURL, create: create, beforePublish: {})
    }

    init(databaseURL: URL, create: Bool, beforePublish: () throws -> Void) throws {
        guard let resolved = realpath(databaseURL.deletingLastPathComponent().path, nil) else {
            throw OwnedAttentionRepositoryError.storage("cannot resolve register directory")
        }
        defer { free(resolved) }
        let directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let databaseURL = directory.appendingPathComponent(databaseURL.lastPathComponent)
        try Self.validateDirectory(directory.path)
        if create {
            try Self.rejectExistingSidecars(databaseURL)
            try Self.provision(databaseURL: databaseURL, beforePublish: beforePublish)
        }
        try Self.validatePrivateFile(databaseURL.path, required: true)
        for suffix in ["-wal", "-shm", "-journal"] {
            try Self.validatePrivateFile(databaseURL.path + suffix, required: false)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw OwnedAttentionRepositoryError.storage("could not open register")
        }
        do {
            guard sqlite3_busy_timeout(handle, 5000) == SQLITE_OK else { throw Self.failure(handle) }
            try Self.validateSchema(handle)
            try Self.validateIntegrity(handle)
            for sql in ["PRAGMA journal_mode = WAL", "PRAGMA synchronous = FULL", "PRAGMA fullfsync = ON"] {
                try Self.execute(handle, sql)
            }
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        database = handle
    }

    private static func validateDirectory(_ path: String) throws {
        var current = URL(fileURLWithPath: path, isDirectory: true)
        var isRegisterDirectory = true
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  (info.st_uid == getuid() || (!isRegisterDirectory && info.st_uid == 0)),
                  ((info.st_mode & 0o022) == 0 || (!isRegisterDirectory && (info.st_mode & S_ISVTX) != 0)) else {
                throw OwnedAttentionRepositoryError.storage("insecure register directory")
            }
            try validateNoExtendedACL(current.path)
            if current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
            isRegisterDirectory = false
        }
    }

    private static func validateNoExtendedACL(_ path: String) throws {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else {
                throw OwnedAttentionRepositoryError.storage("cannot inspect extended ACL")
            }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var index = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, index, &entry) == 0 {
            guard let entry else { throw OwnedAttentionRepositoryError.storage("invalid extended ACL") }
            var tag = acl_tag_t(rawValue: 0)
            guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else {
                throw OwnedAttentionRepositoryError.storage("register has permissive extended ACL")
            }
            index = Int32(ACL_NEXT_ENTRY.rawValue)
        }
        guard errno == EINVAL else { throw OwnedAttentionRepositoryError.storage("cannot inspect extended ACL") }
    }

    private static func provision(databaseURL: URL, beforePublish: () throws -> Void) throws {
        let temporary = databaseURL.deletingLastPathComponent().appendingPathComponent(".owned-attention-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw OwnedAttentionRepositoryError.storage("could not create private provisional register")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard close(descriptor) == 0 else {
            throw OwnedAttentionRepositoryError.storage("could not close provisional register file")
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(temporary.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw OwnedAttentionRepositoryError.storage("could not provision register")
        }
        do {
            try execute(handle, "PRAGMA synchronous = FULL")
            try execute(handle, "PRAGMA fullfsync = ON")
            try execute(handle, schema)
            try execute(handle, identitySchema)
            try execute(handle, metadataSchema)
            try execute(handle, "INSERT INTO owned_attention_metadata (singleton, generation, store_id) VALUES (1, 0, '\(UUID().uuidString)')")
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        guard sqlite3_close_v2(handle) == SQLITE_OK else {
            throw OwnedAttentionRepositoryError.storage("could not close provisional register")
        }
        try beforePublish()
        try rejectExistingSidecars(databaseURL)
        // A hard link publishes an initialized file atomically and never replaces an existing register.
        try FileManager.default.linkItem(at: temporary, to: databaseURL)
        try syncDirectory(databaseURL.deletingLastPathComponent())
    }

    private static func syncDirectory(_ directory: URL) throws {
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard directoryFD >= 0 else { throw OwnedAttentionRepositoryError.storage("cannot open register directory") }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw OwnedAttentionRepositoryError.storage("cannot sync register directory") }
    }

    private static func rejectExistingSidecars(_ url: URL) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            var info = stat()
            if lstat(url.path + suffix, &info) == 0 {
                throw OwnedAttentionRepositoryError.storage("orphan SQLite sidecar exists")
            }
            guard errno == ENOENT else { throw OwnedAttentionRepositoryError.storage("cannot inspect SQLite sidecar") }
        }
    }

    private static func validatePrivateFile(_ path: String, required: Bool) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            if !required && errno == ENOENT { return }
            throw OwnedAttentionRepositoryError.storage("cannot inspect register file")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
            throw OwnedAttentionRepositoryError.storage("insecure register file")
        }
        try validateNoExtendedACL(path)
    }

    deinit { sqlite3_close_v2(database) }

    public func storeIdentity() throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return try readMetadata().storeID
    }

    public func register(producer: UUID, capability: Data, epoch: UUID) throws {
        let digest = try Self.capabilityDigest(capability)
        let initial = try OwnedAttentionState(epoch: epoch, revision: 0, destinations: [])
        try transaction {
            let entry: (String, OwnedAttentionState)?
            do {
                entry = try readEntry(producer: producer, expectedDigest: digest)
            } catch OwnedAttentionRepositoryError.unauthorized {
                throw OwnedAttentionRepositoryError.producerExists
            }
            if let (_, state) = entry {
                guard state.epoch == epoch else {
                    throw OwnedAttentionRepositoryError.producerExists
                }
                return
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM owned_attention", -1, &statement, nil) == SQLITE_OK else { throw Self.failure(database) }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw Self.failure(database) }
            guard sqlite3_column_int64(statement, 0) < 256 else { throw OwnedAttentionRepositoryError.producerQuotaExceeded }
            try writeUnlocked(producer: producer, state: initial, digest: digest, insert: true)
            try advanceGeneration()
        }
    }

    public func read(producer: UUID, capability: Data) throws -> OwnedAttentionState? {
        lock.lock()
        defer { lock.unlock() }
        return try authorizedState(producer: producer, capability: capability)
    }

    /// Trusted in-process projection input. Do not expose this through the control socket.
    public func projectionSnapshot() throws -> OwnedAttentionSnapshot {
        var result: [UUID: OwnedAttentionState] = [:]
        var identities: [OwnedAttentionSlot: UUID] = [:]
        var generation: Int64 = 0
        var storeID: UUID?
        try transaction(readOnly: true) {
            let metadata = try readMetadata()
            generation = metadata.generation
            storeID = metadata.storeID
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT producer FROM owned_attention", -1, &statement, nil) == SQLITE_OK else {
                throw Self.failure(database)
            }
            defer { sqlite3_finalize(statement) }
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { throw Self.failure(database) }
                let bytes = Data(bytes: raw, count: Int(sqlite3_column_bytes(statement, 0)))
                guard let text = String(data: bytes, encoding: .utf8),
                      let producer = UUID(uuidString: text), producer.uuidString == text,
                      result[producer] == nil,
                      let (_, state) = try readEntry(producer: producer) else {
                    throw OwnedAttentionRepositoryError.storage("invalid stored producer")
                }
                result[producer] = state
            }
            var identityStatement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT producer, workspace, surface, notification FROM owned_attention_identity", -1, &identityStatement, nil) == SQLITE_OK else { throw Self.failure(database) }
            defer { sqlite3_finalize(identityStatement) }
            while true {
                let step = sqlite3_step(identityStatement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw Self.failure(database) }
                let values = (0..<4).map { column -> UUID? in
                    guard let raw = sqlite3_column_text(identityStatement, Int32(column)) else { return nil }
                    let data = Data(bytes: raw, count: Int(sqlite3_column_bytes(identityStatement, Int32(column))))
                    guard let text = String(data: data, encoding: .utf8), let value = UUID(uuidString: text), value.uuidString == text else { return nil }
                    return value
                }
                guard let producer = values[0], let workspace = values[1], let surface = values[2], let notification = values[3], result[producer] != nil else {
                    throw OwnedAttentionRepositoryError.storage("invalid projection identity")
                }
                let slot = OwnedAttentionSlot(producerID: producer, target: OwnedAttentionTarget(workspaceID: workspace, surfaceID: surface))
                guard identities.updateValue(notification, forKey: slot) == nil else { throw OwnedAttentionRepositoryError.storage("duplicate projection identity") }
            }
            for (producer, state) in result {
                for destination in state.destinations {
                    let slot = OwnedAttentionSlot(producerID: producer, target: OwnedAttentionTarget(workspaceID: destination.workspaceID, surfaceID: destination.surfaceID))
                    guard identities[slot] != nil else { throw OwnedAttentionRepositoryError.storage("missing projection identity") }
                }
            }
        }
        guard let storeID else { throw OwnedAttentionRepositoryError.storage("missing store identity") }
        return OwnedAttentionSnapshot(storeID: storeID, generation: generation, states: result, identities: identities)
    }

    public func apply(producer: UUID, capability: Data, epoch: UUID, revision: UInt64, destinations: [OwnedAttentionDestination], validate: (OwnedAttentionState) throws -> Void = { _ in }) throws {
        try transaction {
            let current = try authorizedState(producer: producer, capability: capability)
            try validateIdentities(producer: producer, state: current)
            let next = try current.applying(epoch: epoch, revision: revision, destinations: destinations)
            if next != current {
                try validate(current)
                for destination in next.destinations {
                    try ensureIdentity(producer: producer, destination: destination)
                }
                guard try identityCount(producer: producer) <= 4096 else {
                    throw OwnedAttentionRepositoryError.identityQuotaExceeded
                }
                try writeUnlocked(producer: producer, state: next, digest: "", insert: false)
                try advanceGeneration()
            }
        }
    }

    private func identityCount(producer: UUID) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM owned_attention_identity WHERE producer = ?", -1, &statement, nil) == SQLITE_OK else { throw Self.failure(database) }
        defer { sqlite3_finalize(statement) }
        try Self.bind(producer.uuidString, at: 1, to: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Self.failure(database) }
        return sqlite3_column_int64(statement, 0)
    }

    private func ensureIdentity(producer: UUID, destination: OwnedAttentionDestination) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO owned_attention_identity (producer, workspace, surface, notification) VALUES (?, ?, ?, ?) ON CONFLICT (producer, workspace, surface) DO NOTHING"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.failure(database) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in [producer, destination.workspaceID, destination.surfaceID, UUID()].enumerated() {
            try Self.bind(value.uuidString, at: Int32(index + 1), to: statement, database: database)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.failure(database) }
    }

    /// Replace the writer epoch atomically while preserving committed attention.
    public func resume(producer: UUID, capability: Data, expectedEpoch: UUID, requestID: UUID) throws -> OwnedAttentionState {
        var result: OwnedAttentionState?
        try transaction {
            let current = try authorizedState(producer: producer, capability: capability)
            try validateIdentities(producer: producer, state: current)
            if let receipt = try readResumeReceipt(producer: producer), receipt.0 == requestID {
                guard receipt.1 == expectedEpoch else { throw OwnedAttentionRepositoryError.conflictingResume }
                result = current
                return
            }
            guard current.epoch == expectedEpoch else { throw OwnedAttentionStateError.wrongEpoch }
            let next = try OwnedAttentionState(epoch: UUID(), revision: 0, destinations: current.destinations)
            try writeResume(producer: producer, state: next, expectedEpoch: expectedEpoch, requestID: requestID)
            try advanceGeneration()
            result = next
        }
        guard let result else { throw OwnedAttentionRepositoryError.storage("missing committed state") }
        return result
    }

    private func validateIdentities(producer: UUID, state: OwnedAttentionState) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT notification FROM owned_attention_identity WHERE producer = ? AND workspace = ? AND surface = ?", -1, &statement, nil) == SQLITE_OK else { throw Self.failure(database) }
        defer { sqlite3_finalize(statement) }
        for destination in state.destinations {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            for (index, value) in [producer, destination.workspaceID, destination.surfaceID].enumerated() {
                try Self.bind(value.uuidString, at: Int32(index + 1), to: statement, database: database)
            }
            guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
                throw OwnedAttentionRepositoryError.storage("missing projection identity")
            }
            let bytes = Data(bytes: raw, count: Int(sqlite3_column_bytes(statement, 0)))
            guard let text = String(data: bytes, encoding: .utf8), let identity = UUID(uuidString: text), identity.uuidString == text,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw OwnedAttentionRepositoryError.storage("invalid projection identity")
            }
        }
    }

    private func readMetadata() throws -> (generation: Int64, storeID: UUID) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT singleton, generation, store_id FROM owned_attention_metadata", -1, &statement, nil) == SQLITE_OK else { throw Self.failure(database) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 0) == 1, sqlite3_column_type(statement, 1) == SQLITE_INTEGER else {
            throw OwnedAttentionRepositoryError.storage("invalid projection generation")
        }
        let generation = sqlite3_column_int64(statement, 1)
        guard let raw = sqlite3_column_text(statement, 2) else { throw OwnedAttentionRepositoryError.storage("missing store identity") }
        let bytes = Data(bytes: raw, count: Int(sqlite3_column_bytes(statement, 2)))
        guard let text = String(data: bytes, encoding: .utf8), let storeID = UUID(uuidString: text), storeID.uuidString == text,
              generation >= 0, sqlite3_step(statement) == SQLITE_DONE else {
            throw OwnedAttentionRepositoryError.storage("invalid projection generation")
        }
        return (generation, storeID)
    }

    private func advanceGeneration() throws {
        _ = try readMetadata()
        try Self.execute(database, "UPDATE owned_attention_metadata SET generation = generation + 1 WHERE singleton = 1 AND generation < 9223372036854775807")
        guard sqlite3_changes(database) == 1 else { throw OwnedAttentionRepositoryError.storage("projection generation exhausted") }
    }

    private func transaction(readOnly: Bool = false, _ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.execute(database, readOnly ? "BEGIN DEFERRED" : "BEGIN IMMEDIATE")
        do {
            try body()
            try Self.execute(database, "COMMIT")
        } catch {
            try? Self.execute(database, "ROLLBACK")
            throw error
        }
    }

    private func readEntry(producer: UUID, expectedDigest: String? = nil) throws -> (String, OwnedAttentionState)? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT capability_hash, payload FROM owned_attention WHERE producer = ?", -1, &statement, nil) == SQLITE_OK else {
            throw Self.failure(database)
        }
        defer { sqlite3_finalize(statement) }
        try Self.bind(producer.uuidString, at: 1, to: statement, database: database)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let hash = sqlite3_column_text(statement, 0), let text = sqlite3_column_text(statement, 1) else { throw Self.failure(database) }
        do {
            let hashData = Data(bytes: hash, count: Int(sqlite3_column_bytes(statement, 0)))
            guard let digest = String(data: hashData, encoding: .utf8), digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                if expectedDigest != nil { throw OwnedAttentionRepositoryError.unauthorized }
                throw OwnedAttentionRepositoryError.storage("invalid stored capability")
            }
            if let expectedDigest, !Self.equalDigest(digest, expectedDigest) {
                throw OwnedAttentionRepositoryError.unauthorized
            }
            let length = Int(sqlite3_column_bytes(statement, 1))
            return (digest, try JSONDecoder().decode(OwnedAttentionState.self, from: Data(bytes: text, count: length)))
        } catch OwnedAttentionRepositoryError.unauthorized {
            throw OwnedAttentionRepositoryError.unauthorized
        } catch {
            throw OwnedAttentionRepositoryError.storage("invalid stored state")
        }
    }

    private func authorizedState(producer: UUID, capability: Data) throws -> OwnedAttentionState {
        let digest = try Self.capabilityDigest(capability)
        guard let (_, state) = try readEntry(producer: producer, expectedDigest: digest) else {
            throw OwnedAttentionRepositoryError.unauthorized
        }
        return state
    }

    private static func capabilityDigest(_ capability: Data) throws -> String {
        guard capability.count == 32 else { throw OwnedAttentionRepositoryError.unauthorized }
        return SHA256.hash(data: capability).map { String(format: "%02x", $0) }.joined()
    }

    private static func equalDigest(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func writeUnlocked(producer: UUID, state: OwnedAttentionState, digest: String, insert: Bool) throws {
        let payload = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let sql = insert ? "INSERT INTO owned_attention (producer, capability_hash, payload) VALUES (?, ?, ?)" : "UPDATE owned_attention SET payload = ? WHERE producer = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.failure(database) }
        defer { sqlite3_finalize(statement) }
        try Self.bind(insert ? producer.uuidString : payload, at: 1, to: statement, database: database)
        try Self.bind(insert ? digest : producer.uuidString, at: 2, to: statement, database: database)
        if insert { try Self.bind(payload, at: 3, to: statement, database: database) }
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw Self.failure(database) }
    }

    private func readResumeReceipt(producer: UUID) throws -> (UUID, UUID)? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT resume_request, resume_epoch FROM owned_attention WHERE producer = ?", -1, &statement, nil) == SQLITE_OK else { throw Self.failure(database) }
        defer { sqlite3_finalize(statement) }
        try Self.bind(producer.uuidString, at: 1, to: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Self.failure(database) }
        let request = sqlite3_column_text(statement, 0), epoch = sqlite3_column_text(statement, 1)
        if request == nil && epoch == nil { return nil }
        guard let request, let epoch,
              let requestText = String(data: Data(bytes: request, count: Int(sqlite3_column_bytes(statement, 0))), encoding: .utf8),
              let epochText = String(data: Data(bytes: epoch, count: Int(sqlite3_column_bytes(statement, 1))), encoding: .utf8),
              let requestID = UUID(uuidString: requestText), requestID.uuidString == requestText,
              let oldEpoch = UUID(uuidString: epochText), oldEpoch.uuidString == epochText else {
            throw OwnedAttentionRepositoryError.storage("invalid resume receipt")
        }
        return (requestID, oldEpoch)
    }

    private func writeResume(producer: UUID, state: OwnedAttentionState, expectedEpoch: UUID, requestID: UUID) throws {
        let payload = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        var statement: OpaquePointer?
        let sql = "UPDATE owned_attention SET payload = ?, resume_request = ?, resume_epoch = ? WHERE producer = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.failure(database) }
        defer { sqlite3_finalize(statement) }
        try Self.bind(payload, at: 1, to: statement, database: database)
        try Self.bind(requestID.uuidString, at: 2, to: statement, database: database)
        try Self.bind(expectedEpoch.uuidString, at: 3, to: statement, database: database)
        try Self.bind(producer.uuidString, at: 4, to: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw Self.failure(database) }
    }

    private static func bind(_ value: String, at index: Int32, to statement: OpaquePointer?, database: OpaquePointer) throws {
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else { throw failure(database) }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure(database) }
    }

    private static func validateSchema(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = "SELECT type, name, sql FROM sqlite_master WHERE name NOT GLOB 'sqlite_*' ORDER BY name"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw failure(database) }
        defer { sqlite3_finalize(statement) }
        let first = sqlite3_step(statement)
        guard first == SQLITE_ROW else {
            if first != SQLITE_DONE { throw failure(database) }
            throw OwnedAttentionRepositoryError.storage("invalid register schema")
        }
        guard
              let type = sqlite3_column_text(statement, 0), String(cString: type) == "table",
              let name = sqlite3_column_text(statement, 1), String(cString: name) == "owned_attention",
              let definition = sqlite3_column_text(statement, 2), String(cString: definition) == schema else {
            throw OwnedAttentionRepositoryError.storage("invalid register schema")
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let identityType = sqlite3_column_text(statement, 0), String(cString: identityType) == "table",
              let identityName = sqlite3_column_text(statement, 1), String(cString: identityName) == "owned_attention_identity",
              let identityDefinition = sqlite3_column_text(statement, 2), String(cString: identityDefinition) == identitySchema,
              sqlite3_step(statement) == SQLITE_ROW,
              let metadataType = sqlite3_column_text(statement, 0), String(cString: metadataType) == "table",
              let metadataName = sqlite3_column_text(statement, 1), String(cString: metadataName) == "owned_attention_metadata",
              let metadataDefinition = sqlite3_column_text(statement, 2), String(cString: metadataDefinition) == metadataSchema,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw OwnedAttentionRepositoryError.storage("invalid register schema")
        }
    }

    private static func validateIntegrity(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else { throw failure(database) }
        defer { sqlite3_finalize(statement) }
        let first = sqlite3_step(statement)
        guard first == SQLITE_ROW else {
            if first != SQLITE_DONE { throw failure(database) }
            throw OwnedAttentionRepositoryError.storage("register integrity check failed")
        }
        guard let result = sqlite3_column_text(statement, 0), String(cString: result) == "ok" else {
            throw OwnedAttentionRepositoryError.storage("register integrity check failed")
        }
        let next = sqlite3_step(statement)
        guard next == SQLITE_DONE else {
            if next != SQLITE_ROW { throw failure(database) }
            throw OwnedAttentionRepositoryError.storage("register integrity check failed")
        }
    }

    private static func failure(_ database: OpaquePointer) -> OwnedAttentionRepositoryError {
        .storage(String(cString: sqlite3_errmsg(database)))
    }
}
